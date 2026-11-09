import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/framing.dart' as ffi_framing;

import '../../discovery/beacon_id.dart';
import '../p2p_transport.dart';
import '../selecting_p2p_transport.dart' show TransportReadiness;
import '../webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;
import 'lan_advertising_policy.dart';
import 'lan_discovery.dart';
import 'lan_listener.dart';
import 'multicast_lock.dart';

/// Assinatura de `NetworkInterface.list` — extraída para que os testes
/// possam simular "sem rede local nenhuma" sem depender de que a máquina
/// de CI/teste tenha ou não uma interface de rede real.
typedef ListNetworkInterfacesFn = Future<List<NetworkInterface>> Function();

/// Assinatura de `frameForLocalSocket` — extraída para que os testes possam
/// substituir a chamada FFI real (indisponível em `flutter test`, mesmo
/// raciocínio de `JitteredOutbox.sampleJitter` em `outbox.dart`).
typedef FrameFn = Future<Uint8List> Function({required List<int> envelope});

/// Assinatura de `extractFrameFromLocalSocketBuffer` — mesmo raciocínio de
/// [FrameFn].
typedef ExtractFrameFn = Future<(Uint8List?, Uint8List)> Function({required List<int> buffer});

/// Par de conexões TCP `control`/`file` de um mesmo anúncio.
typedef LanConnectionPair = (LanConnection, LanConnection);

/// [P2PTransport] concreto sobre mDNS/DNS-SD (descoberta) + socket TCP
/// (dados) na mesma LAN — Fase 6, F1.
///
/// Papel ativo/passivo decidido pela mesma regra do handshake do protocolo
/// (`docs/protocol.md` §4, `PublicIdentity::is_before`), reaproveitando o
/// sinal que `Core.ensureSession` já devolve — mesma convenção de
/// [WebrtcP2PTransport]. O lado passivo ancora o [LanListener] (singleton do
/// processo) e anuncia via mDNS; o lado ativo procura por mDNS e disca duas
/// conexões TCP (`control`/`file`), cada uma identificada por um preâmbulo
/// (`lan_listener.dart`, decisão de implementação — não normativa em
/// `docs/protocol.md`).
class LanTransport implements P2PTransport, TransportReadiness {
  LanTransport({
    required Core core,
    required ContactId contactId,
    required LanListener listener,
    required LanDiscovery discovery,
    LanAdvertisingPolicy policy = const AlwaysAdvertisePolicy(),
    FrameFn? frame,
    ExtractFrameFn? extractFrame,
    ListNetworkInterfacesFn? listNetworkInterfaces,
    Duration dialTimeout = const Duration(seconds: 2),
  })  : _dialTimeout = dialTimeout,
        _core = core,
        _contactId = contactId,
        _listener = listener,
        _discovery = discovery,
        _policy = policy,
        _frame = frame ?? ffi_framing.frameForLocalSocket,
        _extractFrame = extractFrame ?? ffi_framing.extractFrameFromLocalSocketBuffer,
        _listNetworkInterfaces = listNetworkInterfaces ?? NetworkInterface.list {
    unawaited(_refreshReachability());
  }

  final Core _core;
  final ContactId _contactId;
  final LanListener _listener;
  final LanDiscovery _discovery;
  final LanAdvertisingPolicy _policy;
  final FrameFn _frame;
  final ExtractFrameFn _extractFrame;
  final ListNetworkInterfacesFn _listNetworkInterfaces;

  /// Limite de cada discagem. Um registro mDNS velho pode apontar para um IP
  /// que sumiu da rede: sem limite, `Socket.connect` pendura até o timeout do
  /// SO e o anúncio atual do mesmo par chegaria com ninguém para tentá-lo.
  final Duration _dialTimeout;

  /// Otimista até a primeira checagem terminar — nunca queremos pular um
  /// candidato só porque a checagem de interfaces de rede ainda não voltou.
  bool _isLikelyReachable = true;

  @override
  bool get isLikelyReachable => _isLikelyReachable;

  Future<void> _refreshReachability() async {
    try {
      final interfaces = await _listNetworkInterfaces();
      _isLikelyReachable = interfaces.any((i) => i.addresses.isNotEmpty);
    } catch (_) {
      // Falha ao listar interfaces não deveria nunca acontecer, mas se
      // acontecer, o otimismo é a resposta certa: não bloquear um
      // candidato por causa de uma checagem que não é o próprio transporte.
      _isLikelyReachable = true;
    }
  }

  final _incomingController = StreamController<Uint8List>.broadcast();
  final _incomingFileController = StreamController<Uint8List>.broadcast();
  final _connectionEventsController = StreamController<TransportConnectionEvent>.broadcast();

  LanConnection? _control;
  LanConnection? _file;
  bool _connectStarted = false;
  bool _closed = false;

  /// Preâmbulo sob o qual `connect` registrou a espera no [LanListener] — é
  /// diferente do `device_id` do contato, e `close` precisa cancelar pela
  /// mesma chave, senão a espera sobrevive e é entregue ao transporte seguinte.
  Uint8List? _waitPreamble;

  /// Resultado da busca ativa em andamento, para `close` poder encerrá-la: o
  /// `timeout` de `SelectingP2PTransport` não cancela o `connect`, e é o
  /// `close` dele que impede o loop de seguir escutando mDNS depois do
  /// fallback para o próximo candidato.
  Completer<LanConnectionPair?>? _activeResult;

  @override
  Stream<Uint8List> get incoming => _incomingController.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFileController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEventsController.stream;

  @override
  Future<void> send(Uint8List envelope) async {
    _control!.add(await _frame(envelope: envelope));
  }

  @override
  Future<void> sendFile(Uint8List bytes) async {
    _file!.add(await _frame(envelope: bytes));
  }

  @override
  Future<void> connect() async {
    if (_connectStarted) return;
    _connectStarted = true;
    _connectionEventsController.add(
      const TransportConnectionEvent(TransportConnectionState.connecting),
    );

    try {
      // Lock adquirido antes de qualquer operação mDNS — sem ele, o driver
      // Wi-Fi do Android filtra os pacotes multicast e o NsdManager nunca
      // recebe anúncios nem queries (docs/protocol.md §9.2).
      await MulticastLock.acquire();
      try {
        final beacons = await _core.discoveryBeacons(peerDeviceId: _contactId.deviceId);
        final port = await _listener.ensureListening();

        final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
        final weAreActive = status.outgoingHandshake != null;
        if (kDebugMode) debugPrint('[LanTransport] connect(): porta=$port weAreActive=$weAreActive peer=${_hex(_contactId.deviceId)}');

        if (weAreActive) {
          final dialPreamble = Uint8List.fromList(beacons.dialPreamble);
          final pair = await _connectActive(beacons.scanBeacons, dialPreamble);
          if (pair == null) return; // `close` encerrou a busca
          _control = pair.$1;
          _file = pair.$2;
        } else {
          if (!_policy.shouldAdvertise(_contactId)) {
            // Sem anúncio, o lado ativo nunca vai nos achar por mDNS — falha
            // rápido em vez de esperar o timeout inteiro de
            // `SelectingP2PTransport` para nada.
            throw StateError(
              'LanAdvertisingPolicy decidiu não anunciar este contato agora',
            );
          }
          final instanceName = toHexInstanceName(beacons.advertiseBeacon);
          await _discovery.advertise(instanceName: instanceName, port: port);
          if (kDebugMode) debugPrint('[LanTransport] mDNS anunciado: $instanceName :$port — aguardando TCP...');
          // `close` pode ter rodado durante o `advertise` (lento no mDNS real),
          // quando ainda não havia espera a cancelar: registrar agora deixaria
          // uma espera órfã para o próximo transporte do contato.
          if (_closed) return;
          final listenPreambles = beacons.listenPreambles.map(Uint8List.fromList).toList();
          final alternatives = listenPreambles.length > 1 ? listenPreambles.sublist(1) : null;
          _waitPreamble = listenPreambles.first;
          try {
            _control = await _listener.waitForConnection(
              deviceId: listenPreambles.first,
              channel: LanChannel.control,
              alternativeIdentifiers: alternatives,
            );
            // Mesma janela entre as duas esperas: `close` já cancelou a do canal
            // `file` (ainda inexistente), então não registrar a dele.
            if (_closed) {
              _control!.destroy();
              return;
            }
            _file = await _listener.waitForConnection(
              deviceId: listenPreambles.first,
              channel: LanChannel.file,
              alternativeIdentifiers: alternatives,
            );
          } finally {
            // Esperas resolvidas (ou falhas): a chave deixa de ser nossa. Um
            // `close` tardio não pode cancelar a espera de um transporte mais
            // novo do mesmo contato que reutilizou o preâmbulo.
            _waitPreamble = null;
          }
        }
      } finally {
        // Sockets TCP já abertos (sucesso) ou primeira exceção (falha) —
        // mDNS não é mais necessário em nenhum dos dois casos.
        await MulticastLock.release();
      }

      if (_closed) {
        // `close` correu enquanto esperávamos: os controladores já estão
        // fechados e a conexão não tem dono — descarta em vez de vazar.
        _control?.destroy();
        _file?.destroy();
        return;
      }

      _pump(_control!, _incomingController);
      _pump(_file!, _incomingFileController);
      if (kDebugMode) debugPrint('[LanTransport] conexão TCP estabelecida com ${_hex(_contactId.deviceId)}');
      _connectionEventsController.add(
        const TransportConnectionEvent(TransportConnectionState.connected),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[LanTransport] FALHA em connect(): $e');
      if (!_connectionEventsController.isClosed) {
        _connectionEventsController.add(
          TransportConnectionEvent(TransportConnectionState.failed, reason: e.toString()),
        );
      }
      if (!_closed) {
        rethrow;
      }
    }
  }


  /// Disca o par assim que um anúncio cujo nome de instância bate com algum
  /// beacon da janela de três épocas aparece, e continua escutando até algum
  /// anúncio render um par `control`+`file` completo ou o transporte fechar.
  ///
  /// O nome da instância deriva do beacon, não da porta: o registro de uma
  /// execução anterior do app tem o mesmo nome e uma porta morta, e o NSD
  /// pode entregá-lo antes do atual. Por isso uma recusa não encerra a busca.
  ///
  /// Os dials são concorrentes, no máximo um por porta: o mesmo serviço pode
  /// vir por mais de um endereço (IPv4/IPv6) ou ser reemitido, e dois dials
  /// no mesmo listener passivo deixariam um `control` órfão lá. Porta que já
  /// falhou também não é tentada de novo. Devolve `null` se `close` encerrou.
  Future<LanConnectionPair?> _connectActive(
    List<Uint8List> scanBeacons,
    Uint8List dialPreamble,
  ) async {
    if (_closed) return null;
    final wanted = scanBeacons.map(toHexInstanceName).toSet();
    final result = Completer<LanConnectionPair?>();
    _activeResult = result;
    final triedPorts = <int>{};

    await _discovery.startBrowsing();
    // Uma única assinatura durante toda a busca: o stream é broadcast e um
    // anúncio emitido enquanto um dial está em andamento se perderia.
    final subscription = _discovery.discovered.listen((peer) {
      if (_closed || result.isCompleted) return;
      if (!wanted.contains(peer.instanceName)) return;
      // A chave é só a porta, de propósito: o mesmo serviço chega por mais de
      // um endereço e dois dials no mesmo listener deixariam `control` órfão.
      // O custo é não tentar outro host da mesma porta que falhou.
      if (!triedPorts.add(peer.port)) return;
      unawaited(_tryPeer(peer, dialPreamble, result));
    });
    try {
      return await result.future;
    } finally {
      await subscription.cancel();
      try {
        await _discovery.stopBrowsing();
      } catch (_) {}
    }
  }

  Future<void> _tryPeer(
    LanPeer peer,
    Uint8List dialPreamble,
    Completer<LanConnectionPair?> result,
  ) async {
    LanConnection? control;
    try {
      control = await _dial(peer, LanChannel.control, dialPreamble);
      final file = await _dial(peer, LanChannel.file, dialPreamble);
      if (result.isCompleted) {
        // Outro anúncio ganhou (ou `close` rodou) enquanto este discava.
        control.destroy();
        file.destroy();
        return;
      }
      result.complete((control, file));
    } catch (e) {
      // O par é atômico: um `control` já aberto não pode sobrar sem `file`.
      control?.destroy();
      if (kDebugMode) debugPrint('[LanTransport] dial falhou em $peer: $e');
    }
  }

  Future<LanConnection> _dial(LanPeer peer, LanChannel channel, Uint8List preambleId) async {
    final socket = await Socket.connect(peer.host, peer.port, timeout: _dialTimeout);
    try {
      socket.add(encodePreamble(deviceId: preambleId, channel: channel));
      await socket.flush();
    } catch (_) {
      socket.destroy();
      rethrow;
    }
    return LanConnection(socket: socket, incoming: socket);
  }

  /// Desenquadra `connection.incoming` e publica cada envelope extraído em
  /// `out`. Pausa a subscrição enquanto uma extração está em andamento (a
  /// chamada FFI é assíncrona) para nunca processar dois pedaços do mesmo
  /// buffer fora de ordem.
  void _pump(LanConnection connection, StreamController<Uint8List> out) {
    var buffer = Uint8List(0);
    late final StreamSubscription<Uint8List> sub;

    sub = connection.incoming.listen(
      (chunk) {
        sub.pause();
        unawaited(() async {
          buffer = Uint8List.fromList([...buffer, ...chunk]);
          try {
            while (true) {
              final (extracted, remaining) = await _extractFrame(buffer: buffer);
              buffer = remaining;
              if (extracted == null) break;
              if (!out.isClosed) out.add(extracted);
            }
            sub.resume();
          } catch (_) {
            // Armadilha do relatório da Fase 6, §4: `extract_frame` que
            // rejeita um quadro nunca deve ser tentado de novo sobre o
            // mesmo buffer — a única resposta correta é derrubar a conexão.
            await sub.cancel();
            connection.destroy();
            if (!_connectionEventsController.isClosed) {
              _connectionEventsController.add(
                const TransportConnectionEvent(
                  TransportConnectionState.failed,
                  reason: 'quadro rejeitado pelo enquadramento do socket local',
                ),
              );
            }
          }
        }());
      },
      onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
        connection.destroy();
      },
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    final activeResult = _activeResult;
    if (activeResult != null && !activeResult.isCompleted) activeResult.complete(null);
    final waitPreamble = _waitPreamble;
    if (waitPreamble != null) {
      _listener.cancelWait(deviceId: waitPreamble, channel: LanChannel.control);
      _listener.cancelWait(deviceId: waitPreamble, channel: LanChannel.file);
    }
    try {
      await _discovery.stopAdvertising();
    } catch (_) {}
    try {
      await _discovery.stopBrowsing();
    } catch (_) {}
    try {
      _control?.destroy();
      _file?.destroy();
    } catch (_) {}
    if (!_incomingController.isClosed) await _incomingController.close();
    if (!_incomingFileController.isClosed) await _incomingFileController.close();
    if (!_connectionEventsController.isClosed) await _connectionEventsController.close();
  }
}

/// Formata bytes como string hexadecimal — usado exclusivamente em logs de
/// diagnóstico (apenas sob kDebugMode), nunca em lógica de protocolo.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
