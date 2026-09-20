import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'outbox.dart';
import 'raw_p2p_channel.dart';
import '../rust/ffi/jitter.dart' as ffi_jitter;

/// STUN público, sem TURN — decisão 2.6 do relatório da Fase 3: um relay é
/// exatamente o tipo de infraestrutura confiável que o projeto rejeita
/// (`CLAUDE.md`, "nenhuma infraestrutura confiável"). O preço é que uma
/// fração das conexões entre NATs simétricos nunca fecha — [connectionEvents]
/// emite [TransportConnectionState.failed] de forma explícita nesse caso, em
/// vez de tentar indefinidamente.
const _iceServers = [
  {'urls': 'stun:stun.l.google.com:19302'},
];

const _controlChannelLabel = 'control';
const _fileChannelLabel = 'file';

/// Rótulo de um dos dois `RTCDataChannel` negociados juntos no primeiro SDP
/// — `docs/protocol.md` §11.4 (decisão 2.2 do relatório da Fase 3), para
/// nunca precisar renegociar a oferta quando o pipeline de arquivos (D6)
/// existir.
enum DataChannelKind { control, file }

enum TransportConnectionState { connecting, connected, failed, closed }

class TransportConnectionEvent {
  const TransportConnectionEvent(this.state, {this.reason});

  final TransportConnectionState state;

  /// Só preenchido em [TransportConnectionState.failed] — texto para a UI
  /// explicar por quê (ex.: "NAT simétrico, sem TURN") em vez de um estado
  /// mudo.
  final String? reason;

  @override
  String toString() =>
      'TransportConnectionEvent($state${reason == null ? '' : ', $reason'})';
}

/// Transporte WebRTC concreto — Fase 3, F3; canal `file` ligado na Fase 5.
///
/// O canal `control` carrega `MSG_TEXT`/`FILE_METADATA`/`FILE_FEEDBACK`/
/// `FILE_COMPLETE` e afins; o canal `file`, criado e negociado junto desde a
/// Fase 3 (§11.4/D6), carrega `FILE_SYMBOL`/`AUDIO_CHUNK` — volume alto,
/// não ordenado, sem retransmissão (`ordered:false, maxRetransmits:0`),
/// nunca passa por `Session` (ver `viska_proto::file::transfer`, doc do
/// módulo).
///
/// Callbacks de rede (`onMessage`, `onDataChannel`) nunca chamam a FFI
/// diretamente — só empilham em [incoming] ou [localIceCandidates]; quem
/// consome esses streams decide quando (e em que ordem) processar, longe do
/// callback de rede em si. Essa é a armadilha identificada no relatório da
/// Fase 3: `flutter_webrtc` entrega tudo em callback, e chamar a FFI
/// síncrona de dentro de um callback de rede espalha a lógica de mais um
/// jeito difícil de testar.
class WebrtcTransport implements RawP2PChannel {
  WebrtcTransport({
    Duration iceTimeout = const Duration(seconds: 18),
    Future<Duration> Function()? jitterProvider,
  })  : _iceTimeout = iceTimeout,
        _jitterProvider = jitterProvider ?? _sampleJitterFromRust {
    // `close()` pode rejeitar `_controlChannelOpen` mesmo que `send` nunca
    // tenha sido chamado (ninguém esperando por ela ainda) — sem isto, o
    // runtime do Dart reportaria uma exceção "sem tratamento" nesse caso.
    // `await _controlChannelOpen.future` dentro de `rawSend` continua
    // recebendo o erro normalmente; isto só evita o aviso de zona.
    _controlChannelOpen.future.ignore();
    _fileChannelOpen.future.ignore();
  }

  final Duration _iceTimeout;
  final Future<Duration> Function() _jitterProvider;

  RTCPeerConnection? _pc;
  RTCDataChannel? _controlChannel;
  RTCDataChannel? _fileChannel;
  JitteredOutbox? _outbox;
  Timer? _iceTimeoutTimer;
  bool _reachedConnected = false;
  bool _closed = false;

  /// Resolve quando o canal `control` chega a `RTCDataChannelOpen`. O canal
  /// existe (e `_outbox` também) assim que é criado/recebido, bem antes de
  /// estar de fato aberto — mandar para o `RTCDataChannel` nativo nesse meio
  /// tempo falha ou é descartado silenciosamente pela pilha nativa,
  /// dependendo da plataforma. `send` espera por isto antes de chamar
  /// `channel.send`, em vez de confiar que quem chama nunca manda cedo
  /// demais.
  final _controlChannelOpen = Completer<void>();

  /// Como [_controlChannelOpen], para o canal `file` — os dois abrem de
  /// forma independente (nada garante ordem entre eles no SCTP).
  final _fileChannelOpen = Completer<void>();

  JitteredOutbox? _fileOutbox;

  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();
  final _localIceCandidates = StreamController<RTCIceCandidate>.broadcast();
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override
  Stream<RTCIceCandidate> get localIceCandidates => _localIceCandidates.stream;

  /// Bytes crus recebidos no canal `control` — envelopes ainda cifrados,
  /// prontos para `Core.decryptIncoming`. Quem consome decide quando: este
  /// stream só empilha, nunca decifra.
  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Como [incoming], para o canal `file` — símbolo/pedaço de áudio selado,
  /// pronto para `Core.ingestIncomingFileSymbol`/`ingestIncomingAudioChunk`.
  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;

  /// Cria a oferta como iniciador: monta o `RTCPeerConnection`, cria os dois
  /// `RTCDataChannel` (para os dois saírem no mesmo SDP), e devolve o texto
  /// da oferta para a camada de sinalização (F4) publicar.
  @override
  Future<String> createOffer() async {
    final pc = await _ensurePeerConnection();

    final control = await pc.createDataChannel(
      _controlChannelLabel,
      RTCDataChannelInit()..ordered = true,
    );
    _wireChannel(DataChannelKind.control, control);

    final file = await pc.createDataChannel(
      _fileChannelLabel,
      RTCDataChannelInit()
        ..ordered = false
        ..maxRetransmits = 0,
    );
    _wireChannel(DataChannelKind.file, file);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _startIceTimeout();

    return offer.sdp ?? '';
  }

  /// Processa uma oferta remota como respondedor: monta o
  /// `RTCPeerConnection`, escuta `onDataChannel` (os dois canais chegam
  /// prontos, criados pelo iniciador), e devolve o texto da resposta.
  @override
  Future<String> createAnswerForOffer(String remoteSdp) async {
    final pc = await _ensurePeerConnection();

    pc.onDataChannel = (channel) {
      switch (channel.label) {
        case _controlChannelLabel:
          _wireChannel(DataChannelKind.control, channel);
        case _fileChannelLabel:
          _wireChannel(DataChannelKind.file, channel);
      }
    };

    await pc.setRemoteDescription(RTCSessionDescription(remoteSdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _startIceTimeout();

    return answer.sdp ?? '';
  }

  /// Aplica a resposta remota — só o iniciador chama isto, depois de receber
  /// a resposta via sinalização.
  @override
  Future<void> applyRemoteAnswer(String remoteSdp) async {
    final pc = _pc;
    if (pc == null) {
      throw StateError('applyRemoteAnswer chamado antes de createOffer');
    }
    await pc.setRemoteDescription(RTCSessionDescription(remoteSdp, 'answer'));
  }

  /// Alimenta um candidato ICE remoto, recebido via sinalização.
  @override
  Future<void> addRemoteIceCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    final pc = _pc;
    if (pc == null) {
      throw StateError('addRemoteIceCandidate chamado antes da conexão existir');
    }
    await pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
  }

  /// Enfileira `envelope` (bytes já cifrados) para envio no canal `control`,
  /// com o jitter de `docs/protocol.md` §6.5 aplicado antes de cada um.
  @override
  Future<void> send(Uint8List envelope) {
    final outbox = _outbox;
    if (outbox == null) {
      return Future.error(
        StateError('send chamado antes do canal control existir'),
      );
    }
    return outbox.enqueue(envelope);
  }

  /// Enfileira `bytes` (símbolo/pedaço de áudio já selado) para envio no
  /// canal `file`, com o mesmo jitter de `docs/protocol.md` §6.5 — a
  /// propriedade de indistinguibilidade de tráfego não faz exceção para
  /// volume alto.
  @override
  Future<void> sendFile(Uint8List bytes) {
    final outbox = _fileOutbox;
    if (outbox == null) {
      return Future.error(
        StateError('sendFile chamado antes do canal file existir'),
      );
    }
    return outbox.enqueue(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _iceTimeoutTimer?.cancel();
    _outbox?.close();
    _fileOutbox?.close();
    if (!_controlChannelOpen.isCompleted) {
      // Nenhum `send` deveria ficar esperando um canal que nunca vai abrir —
      // rejeita em vez de travar para sempre.
      _controlChannelOpen.completeError(
        StateError('WebrtcTransport fechado antes do canal control abrir'),
      );
    }
    if (!_fileChannelOpen.isCompleted) {
      _fileChannelOpen.completeError(
        StateError('WebrtcTransport fechado antes do canal file abrir'),
      );
    }

    await _controlChannel?.close();
    await _fileChannel?.close();
    await _pc?.close();
    await _pc?.dispose();

    _connectionEvents.add(const TransportConnectionEvent(TransportConnectionState.closed));
    await _connectionEvents.close();
    await _localIceCandidates.close();
    await _incoming.close();
    await _incomingFile.close();
  }

  Future<RTCPeerConnection> _ensurePeerConnection() async {
    final existing = _pc;
    if (existing != null) return existing;

    final pc = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        _localIceCandidates.add(candidate);
      }
    };
    pc.onIceConnectionState = _handleIceConnectionState;
    _pc = pc;
    return pc;
  }

  void _wireChannel(DataChannelKind kind, RTCDataChannel channel) {
    switch (kind) {
      case DataChannelKind.control:
        _controlChannel = channel;
        _outbox = JitteredOutbox(
          rawSend: (bytes) async {
            await _controlChannelOpen.future;
            await channel.send(RTCDataChannelMessage.fromBinary(bytes));
          },
          sampleJitter: _jitterProvider,
        );
        channel.onMessage = (message) {
          if (message.isBinary) {
            _incoming.add(message.binary);
          }
          // Mensagens de texto nunca deveriam chegar aqui — o protocolo só
          // manda envelopes binários (§6) — mas ignorar em vez de tratar
          // como erro evita derrubar a conexão por causa de lixo de um par
          // que fale uma versão diferente.
        };
        channel.onDataChannelState = (state) {
          if (state == RTCDataChannelState.RTCDataChannelOpen) {
            _handleControlChannelOpen();
          }
        };
      case DataChannelKind.file:
        _fileChannel = channel;
        _fileOutbox = JitteredOutbox(
          rawSend: (bytes) async {
            await _fileChannelOpen.future;
            await channel.send(RTCDataChannelMessage.fromBinary(bytes));
          },
          sampleJitter: _jitterProvider,
        );
        channel.onMessage = (message) {
          if (message.isBinary) {
            _incomingFile.add(message.binary);
          }
        };
        channel.onDataChannelState = (state) {
          if (state == RTCDataChannelState.RTCDataChannelOpen &&
              !_fileChannelOpen.isCompleted) {
            _fileChannelOpen.complete();
          }
        };
    }
  }

  void _handleControlChannelOpen() {
    if (!_controlChannelOpen.isCompleted) {
      _controlChannelOpen.complete();
    }
    if (_reachedConnected) return;
    _reachedConnected = true;
    _iceTimeoutTimer?.cancel();
    _connectionEvents.add(const TransportConnectionEvent(TransportConnectionState.connected));
  }

  void _handleIceConnectionState(RTCIceConnectionState state) {
    final event = mapIceConnectionState(state);
    if (event == null) return;

    if (event.state == TransportConnectionState.failed) {
      _iceTimeoutTimer?.cancel();
    }
    _connectionEvents.add(event);
  }

  void _startIceTimeout() {
    _iceTimeoutTimer?.cancel();
    _iceTimeoutTimer = Timer(_iceTimeout, () {
      if (_reachedConnected || _closed) return;
      _connectionEvents.add(
        const TransportConnectionEvent(
          TransportConnectionState.failed,
          reason:
              'Não foi possível conectar diretamente dentro do tempo limite — '
              'provável NAT simétrico dos dois lados. Tente o modo local.',
        ),
      );
      // Decisão 2.6: falhar de forma explícita, nunca tentar indefinidamente
      // — fecha a tentativa em vez de deixar o ICE continuar sozinho.
      unawaited(close());
    });
  }

  static Future<Duration> _sampleJitterFromRust() async {
    final millis = await ffi_jitter.sampleJitterDelayMs();
    return Duration(milliseconds: millis.toInt());
  }
}

/// Traduz um `RTCIceConnectionState` para um [TransportConnectionEvent], ou
/// `null` quando o estado não muda nada que a UI precise saber (`checking`,
/// `new`, etc.). Função livre e pura — sem depender de nenhum
/// `RTCPeerConnection` de verdade — de propósito, para poder testar o
/// mapeamento sem canal de plataforma nenhum.
TransportConnectionEvent? mapIceConnectionState(RTCIceConnectionState state) {
  switch (state) {
    case RTCIceConnectionState.RTCIceConnectionStateFailed:
      return const TransportConnectionEvent(
        TransportConnectionState.failed,
        reason: 'ICE falhou — provável NAT simétrico dos dois lados.',
      );
    case RTCIceConnectionState.RTCIceConnectionStateClosed:
      return const TransportConnectionEvent(TransportConnectionState.closed);
    case RTCIceConnectionState.RTCIceConnectionStateNew:
    case RTCIceConnectionState.RTCIceConnectionStateChecking:
    case RTCIceConnectionState.RTCIceConnectionStateConnected:
    case RTCIceConnectionState.RTCIceConnectionStateCompleted:
    case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
    case RTCIceConnectionState.RTCIceConnectionStateCount:
      // "Connected"/"completed" já são sinalizados com mais precisão pela
      // abertura do canal `control` (`_handleControlChannelOpen`) — o ICE
      // pode ficar "connected" um instante antes do DataChannel em si abrir.
      // "Disconnected" é frequentemente transitório (perda de pacote UDP
      // passageira); não é tratado como falha por conta própria — só o
      // timeout explícito ou um "failed" de verdade encerram a tentativa.
      return null;
  }
}
