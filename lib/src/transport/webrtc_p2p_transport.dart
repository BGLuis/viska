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
  })  : _core = core,
        _contactId = contactId,
        _webrtc = webrtcTransport ?? WebrtcTransport(),
        _signaling = signalingBackend ?? MqttSignalingBackend(host: signalingHost);

  final Core _core;
  final ContactId _contactId;
  final RawP2PChannel _webrtc;
  final SignalingBackend _signaling;

  String? _publishTopic;
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

    final topics = await _core.signalingTopics(peerDeviceId: _contactId.deviceId);
    _publishTopic = topics.publishTopic;

    await _signaling.connect();
    await _signaling.subscribeTopics(topics.subscribeTopics);
    _signalingSub = _signaling.incoming.listen(_handleSignalingMessage);
    _webrtcEventsSub = _webrtc.connectionEvents.listen(_handleWebrtcConnectionEvent);

    final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
    final weAreOfferer = status.outgoingHandshake != null;

    if (weAreOfferer) {
      final offerSdp = await _webrtc.createOffer();
      _localIceSub = _webrtc.localIceCandidates.listen(_publishLocalCandidate);
      await _publish(SignalingPayload.offer(offerSdp));
    }
    // Respondedor: nada a fazer ainda — espera a oferta chegar por
    // `_handleSignalingMessage`.
  }

  @override
  Future<void> close() async {
    await _signalingSub?.cancel();
    await _localIceSub?.cancel();
    await _webrtcEventsSub?.cancel();
    if (!_signalingClosed) {
      _signalingClosed = true;
      await _signaling.disconnect();
    }
    await _webrtc.close();
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
        final answerSdp = await _webrtc.createAnswerForOffer(decoded.sdp!);
        _localIceSub ??= _webrtc.localIceCandidates.listen(_publishLocalCandidate);
        await _publish(SignalingPayload.answer(answerSdp));
      case SignalingMessageKind.answer:
        await _webrtc.applyRemoteAnswer(decoded.sdp!);
      case SignalingMessageKind.iceCandidate:
        await _webrtc.addRemoteIceCandidate(
          candidate: decoded.candidate!,
          sdpMid: decoded.sdpMid,
          sdpMLineIndex: decoded.sdpMLineIndex,
        );
    }
  }

  Future<void> _publishLocalCandidate(RTCIceCandidate candidate) async {
    final text = candidate.candidate;
    if (text == null) return;
    await _publish(
      SignalingPayload.iceCandidate(
        candidate: text,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ),
    );
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
      unawaited(_signaling.disconnect());
    }
  }
}
