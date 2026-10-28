import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceCandidate;
import 'package:viska/src/rust/ffi/core.dart';

import 'p2p_transport.dart';
import 'raw_p2p_channel.dart';
import 'signaling/mqtt_signaling_backend.dart';
import 'signaling/signaling_backend.dart';
import 'signaling/signaling_payload_codec.dart';
import 'webrtc_transport.dart';

/// [P2PTransport] concreto: WebRTC para os dados, MQTT (F4) para a
/// sinalização — Fase 3, F5.
///
/// Papel na negociação SDP (quem oferta, quem responde) decidido pela mesma
/// regra do handshake do protocolo (`docs/protocol.md` §4,
/// `PublicIdentity::is_before`): reaproveita o sinal que `Core.ensureSession`
/// já devolve (`outgoingHandshake` presente ⟺ somos o iniciador do AKE ⟺
/// somos também quem oferta o SDP), em vez de negociar isso de novo.
///
/// Fecha o socket MQTT assim que o canal `control` abre (decisão 2.3 do
/// relatório da Fase 3) — reduz a janela em que o broker público observa o
/// par. Reconexão automática de sinalização após queda do `DataChannel`
/// **não** está implementada nesta fase: fica para quem gerencia o ciclo de
/// vida da conexão ao longo do tempo (retomar do zero com
/// `P2PTransportRouter`, recriando este objeto).
class WebrtcP2PTransport implements P2PTransport {
  WebrtcP2PTransport({
    required Core core,
    required ContactId contactId,
    RawP2PChannel? webrtcTransport,
    SignalingBackend? signalingBackend,
    String signalingHost = 'broker.emqx.io',
    Duration signalingRefreshInterval = const Duration(seconds: 4),
  })  : _core = core,
        _signalingRefreshInterval = signalingRefreshInterval,
        _contactId = contactId,
        _webrtc = webrtcTransport ?? WebrtcTransport(),
        _signaling = signalingBackend ?? MqttSignalingBackend(host: signalingHost);

  final Core _core;
  final ContactId _contactId;
  final RawP2PChannel _webrtc;
  final SignalingBackend _signaling;
  final Duration _signalingRefreshInterval;

  String? _publishTopic;
  bool _isOfferer = false;
  String? _offerSdp;
  String? _answerSdp;
  bool _answerApplied = false;
  final List<SignalingPayload> _localCandidates = [];
  Timer? _signalingRefreshTimer;
  bool _refreshing = false;

  /// Mensagens de sinalização processadas uma por vez: tratar a oferta é
  /// assíncrono, e um candidato que chegasse no meio seria aplicado numa
  /// conexão que ainda não existe.
  Future<void> _signalingQueue = Future.value();

  /// Candidatos remotos só podem ser aplicados depois da descrição remota
  /// (oferta no respondedor, resposta no ofertante). Com a republicação de
  /// §8.2, um candidato pode chegar antes dela; fica guardado até lá.
  bool _remoteDescriptionApplied = false;
  final List<SignalingPayload> _pendingRemoteCandidates = [];
  final Set<String> _appliedRemoteCandidates = {};
  StreamSubscription<SignalingMessage>? _signalingSub;
  StreamSubscription<RTCIceCandidate>? _localIceSub;
  StreamSubscription<TransportConnectionEvent>? _webrtcEventsSub;
  bool _signalingClosed = false;
  bool _connectStarted = false;

  @override
  Stream<Uint8List> get incoming => _webrtc.incoming;

  @override
  Stream<Uint8List> get incomingFile => _webrtc.incomingFile;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _webrtc.connectionEvents;

  @override
  Future<void> send(Uint8List envelope) => _webrtc.send(envelope);

  @override
  Future<void> sendFile(Uint8List bytes) => _webrtc.sendFile(bytes);

  @override
  Future<void> connect() async {
    if (_connectStarted) return;
    _connectStarted = true;

    await _connectSignaling();
    _signalingSub = _signaling.incoming.listen(_enqueueSignalingMessage);
    _webrtcEventsSub = _webrtc.connectionEvents.listen(_handleWebrtcConnectionEvent);

    final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
    _isOfferer = status.outgoingHandshake != null;

    if (_isOfferer) {
      _offerSdp = await _webrtc.createOffer();
      _localIceSub = _webrtc.localIceCandidates.listen(_publishLocalCandidate);
      await _publish(SignalingPayload.offer(_offerSdp!));
    }
    // Respondedor: nada a fazer ainda — espera a oferta chegar por
    // `_handleSignalingMessage`.

    // QoS 0 sem retain: o que é publicado enquanto o par não está inscrito se
    // perde. §8.2 prevê que as pontas republiquem; até o DataChannel abrir,
    // reconecta a sinalização se ela caiu e quem oferta republica oferta e
    // candidatos.
    _signalingRefreshTimer = Timer.periodic(
      _signalingRefreshInterval,
      (_) => unawaited(_refreshSignaling()),
    );
  }

  /// Conecta (no-op se já conectado) e assina os tópicos recalculados agora,
  /// porque a época pode ter virado desde a última vez.
  Future<void> _connectSignaling() async {
    final topics = await _core.signalingTopics(peerDeviceId: _contactId.deviceId);
    _publishTopic = topics.publishTopic;
    await _signaling.connect();
    await _signaling.subscribeTopics(topics.subscribeTopics);
  }

  Future<void> _refreshSignaling() async {
    if (_signalingClosed || _refreshing) return;
    _refreshing = true;
    try {
      await _connectSignaling();
      if (_isOfferer && !_answerApplied && _offerSdp != null) {
        await _publish(SignalingPayload.offer(_offerSdp!));
        await _republishLocalCandidates();
      }
    } catch (_) {
      // Broker inalcançável agora: a próxima rodada tenta de novo.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _republishLocalCandidates() async {
    for (final candidate in List.of(_localCandidates)) {
      await _publish(candidate);
    }
  }

  @override
  Future<void> close() async {
    _signalingRefreshTimer?.cancel();
    await _signalingSub?.cancel();
    await _localIceSub?.cancel();
    await _webrtcEventsSub?.cancel();
    if (!_signalingClosed) {
      _signalingClosed = true;
      await _signaling.disconnect();
    }
    await _webrtc.close();
  }

  void _enqueueSignalingMessage(SignalingMessage message) {
    _signalingQueue = _signalingQueue
        .then((_) => _handleSignalingMessage(message))
        .catchError((Object _) {
      // Uma mensagem que falha não pode travar a fila das seguintes.
    });
  }

  Future<void> _handleSignalingMessage(SignalingMessage message) async {
    final opened = await _core.openSignalingPayload(
      peerDeviceId: _contactId.deviceId,
      sealed: message.payload,
    );
    if (opened == null) return;

    final SignalingPayload decoded;
    try {
      decoded = SignalingPayload.decode(opened);
    } on FormatException {
      // Autenticado (passou pelo AEAD), mas não bate com o formato interno
      // esperado — mesma política de silêncio do resto da sinalização, não
      // é um erro para propagar.
      return;
    }

    switch (decoded.kind) {
      case SignalingMessageKind.offer:
        if (_isOfferer) return;
        final cachedAnswer = _answerSdp;
        if (cachedAnswer != null) {
          // Oferta republicada: a nossa resposta provavelmente se perdeu.
          // Responder de novo com a mesma SDP, sem renegociar a conexão.
          await _publish(SignalingPayload.answer(cachedAnswer));
          await _republishLocalCandidates();
          return;
        }
        _answerSdp = await _webrtc.createAnswerForOffer(decoded.sdp!);
        _localIceSub ??= _webrtc.localIceCandidates.listen(_publishLocalCandidate);
        await _onRemoteDescriptionApplied();
        await _publish(SignalingPayload.answer(_answerSdp!));
      case SignalingMessageKind.answer:
        if (!_isOfferer || _answerApplied) return;
        _answerApplied = true;
        await _webrtc.applyRemoteAnswer(decoded.sdp!);
        await _onRemoteDescriptionApplied();
      case SignalingMessageKind.iceCandidate:
        if (!_remoteDescriptionApplied) {
          _pendingRemoteCandidates.add(decoded);
          return;
        }
        await _applyRemoteCandidate(decoded);
    }
  }

  Future<void> _onRemoteDescriptionApplied() async {
    _remoteDescriptionApplied = true;
    final pending = List.of(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      await _applyRemoteCandidate(candidate);
    }
  }

  Future<void> _applyRemoteCandidate(SignalingPayload candidate) async {
    // A republicação traz o mesmo candidato várias vezes.
    if (!_appliedRemoteCandidates.add(candidate.candidate!)) return;
    await _webrtc.addRemoteIceCandidate(
      candidate: candidate.candidate!,
      sdpMid: candidate.sdpMid,
      sdpMLineIndex: candidate.sdpMLineIndex,
    );
  }

  Future<void> _publishLocalCandidate(RTCIceCandidate candidate) async {
    final text = candidate.candidate;
    if (text == null) return;
    final payload = SignalingPayload.iceCandidate(
      candidate: text,
      sdpMid: candidate.sdpMid,
      sdpMLineIndex: candidate.sdpMLineIndex,
    );
    _localCandidates.add(payload);
    try {
      await _publish(payload);
    } catch (_) {
      // Fica guardado em `_localCandidates` e sai na próxima republicação.
    }
  }

  Future<void> _publish(SignalingPayload payload) async {
    final topic = _publishTopic;
    if (topic == null) return;
    final sealed = await _core.sealSignalingPayload(
      peerDeviceId: _contactId.deviceId,
      payloadBytes: payload.encode(),
    );
    await _signaling.publish(topic, sealed);
  }

  void _handleWebrtcConnectionEvent(TransportConnectionEvent event) {
    if (event.state == TransportConnectionState.connected && !_signalingClosed) {
      _signalingClosed = true;
      _signalingRefreshTimer?.cancel();
      unawaited(_signaling.disconnect());
    }
  }
}
