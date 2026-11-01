import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceCandidate;
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/raw_p2p_channel.dart';
import 'package:viska/src/transport/signaling/signaling_backend.dart';
import 'package:viska/src/transport/webrtc_p2p_transport.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

/// Só implementa o que `WebrtcP2PTransport` de fato chama — o resto
/// arremessa `UnimplementedError` de propósito, para que um teste que
/// dependesse de um método não coberto falhasse alto e claro, em vez de
/// silenciosamente devolver um valor padrão sem sentido.
class _FakeCore implements Core {
  _FakeCore({
    required this.topics,
    required this.sessionStatus_,
  });

  final SignalingTopicsDto topics;
  final SessionStatusDto sessionStatus_;

  final sealedSignalingCalls = <Uint8List>[];
  final openedSignalingCalls = <Uint8List>[];

  /// Payload devolvido por `openSignalingPayload` — configurável por teste;
  /// por padrão, ecoa de volta os bytes que `sealSignalingPayload` recebeu
  /// (simula um seal/open ida-e-volta sem AEAD de verdade).
  Uint8List? Function(Uint8List sealed)? openSignalingPayloadHandler;

  @override
  Future<SignalingTopicsDto> signalingTopics({required List<int> peerDeviceId}) async => topics;

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async => sessionStatus_;

  @override
  Future<Uint8List> sealSignalingPayload({
    required List<int> peerDeviceId,
    required List<int> payloadBytes,
  }) async {
    final bytes = Uint8List.fromList(payloadBytes);
    sealedSignalingCalls.add(bytes);
    return bytes;
  }

  @override
  Future<Uint8List?> openSignalingPayload({
    required List<int> peerDeviceId,
    required List<int> sealed,
  }) async {
    final bytes = Uint8List.fromList(sealed);
    openedSignalingCalls.add(bytes);
    return openSignalingPayloadHandler != null ? openSignalingPayloadHandler!(bytes) : bytes;
  }

  @override
  Future<IncomingMessageDto?> decryptIncoming({
    required List<int> peerDeviceId,
    required List<int> envelope,
  }) =>
      throw UnimplementedError();

  @override
  Future<Uint8List?> feedHandshake({
    required List<int> peerDeviceId,
    required List<int> bytes,
  }) =>
      throw UnimplementedError();

  @override
  Future<DiscoveryBeaconsDto> discoveryBeacons({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<List<SealedMessageDto>> flushPending({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<List<ContactDto>> listContacts() => throw UnimplementedError();

  @override
  Future<ContactDto?> matchDiscoveredBeacon({required List<int> beacon}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> myDeviceId() => throw UnimplementedError();

  @override
  Future<List<MessageDto>> listMessages({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<List<MessageDto>> listMessagesPaginated({
    required List<int> peerDeviceId,
    PlatformInt64? sinceId,
    BigInt? limit,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> markMessageSent({required PlatformInt64 messageId}) => throw UnimplementedError();

  @override
  Future<Uint8List> myQrPayload() => throw UnimplementedError();

  @override
  Future<ContactDto> pairFromQr({required List<int> payload, String? nickname}) =>
      throw UnimplementedError();

  @override
  Future<String?> myNickname() async => null;

  @override
  Future<void> setMyNickname({required String nickname}) async {}

  @override
  Future<void> setContactNickname({
    required List<int> contactDeviceId,
    required String nickname,
  }) async {}

  @override
  Future<String> computeSasCode({required List<int> peerPayload}) async => '123456';

  @override
  Future<SafetyNumberDto> safetyNumber({required List<int> contactDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<SealedMessageDto> sealOutgoingText({
    required List<int> peerDeviceId,
    required String body,
  }) =>
      throw UnimplementedError();

  @override
  Future<SessionStatusDto?> sessionStatus({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  // Fase 4/5 — transferência de arquivo e nota de voz: nada neste teste de
  // transporte chama estes métodos; stubs só para o fake continuar
  // implementando `Core` por inteiro.
  @override
  Future<void> cancelTransfer({required List<int> fileId}) => throw UnimplementedError();

  @override
  Future<Uint8List> fileFeedback({
    required List<int> peerDeviceId,
    required List<int> fileId,
  }) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> finishReceiveAudio({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> finishReceiveFile({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) =>
      throw UnimplementedError();

  @override
  Future<IngestedChunkDto?> ingestIncomingWireBytes({required List<int> wireBytes}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List?> nextOutgoingWireChunk({required List<int> fileId}) =>
      throw UnimplementedError();

  @override
  Future<List<FileOfferDto>> pendingAudioOffers({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<List<FileOfferDto>> pendingFileOffers({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> decodeAudioToWav({required List<int> internalBytes}) =>
      throw UnimplementedError();

  @override
  Future<void> sanitizeAndStageAudio({
    required String sourcePath,
    required String destinationPath,
  }) =>
      throw UnimplementedError();

  @override
  Future<SendAudioStartedDto> startSendAudio({
    required List<int> peerDeviceId,
    required String audioPath,
    required bool useLan,
  }) =>
      throw UnimplementedError();

  @override
  Future<SendFileStartedDto> startSendFile({
    required List<int> peerDeviceId,
    required String filePath,
    required bool useLan,
  }) =>
      throw UnimplementedError();

  @override
  Future<TransferProgressDto?> transferProgress({required List<int> fileId}) =>
      throw UnimplementedError();

  @override
  Future<void> emergencyErase() => throw UnimplementedError();

  @override
  Future<PlatformInt64> getEphemeralTtl({required List<int> contactDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<bool> isLocked() => throw UnimplementedError();

  @override
  Future<List<Uint8List>> listActiveFileTransferIds() => throw UnimplementedError();

  @override
  Future<void> lock() => throw UnimplementedError();

  @override
  Future<void> markMessageRead({required PlatformInt64 messageId}) => throw UnimplementedError();

  @override
  Future<void> setEphemeralTtl({
    required List<int> contactDeviceId,
    required PlatformInt64 ttlSecs,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> sweepExpiredMessages() => throw UnimplementedError();

  @override
  Future<void> unlock() => throw UnimplementedError();

  @override
  Future<void> addReaction({
    required U8Array16 contactDeviceId,
    required PlatformInt64 targetMsgId,
    required String emoji,
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> addReactionByGlobalId({
    required U8Array16 contactDeviceId,
    required String targetGlobalId,
    required String emoji,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> markMessageDelivered({required PlatformInt64 messageId}) =>
      throw UnimplementedError();

  @override
  Future<SealedMessageDto> sealOutgoingReceipt({
    required List<int> peerDeviceId,
    required String targetId,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> configureDuressPin({
    required String duressPin,
    required int actionMode,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> exportEncryptedBackup({required String destPath}) =>
      throw UnimplementedError();

  @override
  Future<void> restoreEncryptedBackup({
    required String mnemonic,
    required String srcPath,
  }) =>
      throw UnimplementedError();

  @override
  Future<String?> getConfig({required String key}) => throw UnimplementedError();

  @override
  Future<void> setConfig({required String key, required String value}) =>
      throw UnimplementedError();

  @override
  Future<bool> isContactVerified({required List<int> contactDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<void> verifyContact({
    required List<int> contactDeviceId,
    required bool verified,
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> isKeyChanged({required List<int> contactDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<void> acceptFileOffer({required List<int> fileId}) => throw UnimplementedError();

  @override
  Future<void> rejectFileOffer({required List<int> fileId}) => throw UnimplementedError();

  @override
  Future<List<FileOfferDto>> unconfirmedFileOffers({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<BigInt> autoAcceptFileSizeLimit() => throw UnimplementedError();

  @override
  Future<void> setAutoAcceptFileSizeLimit({required BigInt limitBytes}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List?> buildControlSuites({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<ContactDto> repairFromQr({required List<int> payload}) => throw UnimplementedError();
}

class _FakeRawP2PChannel implements RawP2PChannel {
  final offerCalls = <void>[];
  final answerCalls = <String>[];
  final remoteAnswerCalls = <String>[];
  final remoteCandidateCalls = <Map<String, Object?>>[];
  final sendCalls = <Uint8List>[];
  final sendFileCalls = <Uint8List>[];
  var closed = false;

  String offerSdpToReturn = 'v=0 OFFER';
  String answerSdpToReturn = 'v=0 ANSWER';

  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();
  final _localIceCandidates = StreamController<RTCIceCandidate>.broadcast();
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();

  @override
  Future<String> createOffer() async {
    offerCalls.add(null);
    return offerSdpToReturn;
  }

  @override
  Future<String> createAnswerForOffer(String remoteSdp) async {
    answerCalls.add(remoteSdp);
    return answerSdpToReturn;
  }

  @override
  Future<void> applyRemoteAnswer(String remoteSdp) async {
    remoteAnswerCalls.add(remoteSdp);
  }

  @override
  Future<void> addRemoteIceCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    remoteCandidateCalls.add({
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  @override
  Future<void> send(Uint8List envelope) async {
    sendCalls.add(envelope);
  }

  @override
  Future<void> sendFile(Uint8List bytes) async {
    sendFileCalls.add(bytes);
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;

  @override
  Stream<RTCIceCandidate> get localIceCandidates => _localIceCandidates.stream;

  @override
  Future<void> close() async {
    closed = true;
  }

  void emitConnectionEvent(TransportConnectionEvent event) => _connectionEvents.add(event);
  void emitLocalCandidate(RTCIceCandidate candidate) => _localIceCandidates.add(candidate);
  void emitIncoming(Uint8List bytes) => _incoming.add(bytes);
  void emitIncomingFile(Uint8List bytes) => _incomingFile.add(bytes);
}

class _FakeSignalingBackend implements SignalingBackend {
  final publishCalls = <MapEntry<String, Uint8List>>[];
  final subscribedTopicsCalls = <List<String>>[];
  var connectCalls = 0;
  var disconnectCalls = 0;

  final _incoming = StreamController<SignalingMessage>.broadcast();

  @override
  Future<void> connect() async => connectCalls++;

  @override
  Future<void> subscribeTopics(List<String> topics) async {
    subscribedTopicsCalls.add(topics);
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    publishCalls.add(MapEntry(topic, payload));
  }

  @override
  Stream<SignalingMessage> get incoming => _incoming.stream;

  @override
  Future<void> disconnect() async => disconnectCalls++;

  void emit(SignalingMessage message) => _incoming.add(message);
}

/// Decodifica o payload interno (`byte 0 = kind`) só o suficiente para os
/// testes inspecionarem o que foi publicado, sem importar
/// `signaling_payload_codec.dart` (que já tem seus próprios testes).
Map<String, Object?> _decodeTestPayload(Uint8List bytes) {
  final kind = bytes[0];
  final body = utf8.decode(bytes.sublist(1));
  if (kind == 0 || kind == 1) {
    return {'kind': kind, 'sdp': body};
  }
  return {'kind': kind, ...jsonDecode(body) as Map<String, dynamic>};
}

void main() {
  group('WebrtcP2PTransport', () {
    late ContactId contact;
    late SignalingTopicsDto topics;

    setUp(() {
      contact = ContactId(List.generate(16, (i) => i));
      topics = SignalingTopicsDto(
        publishTopic: 'pub-topic',
        subscribeTopics: ['sub-1', 'sub-2', 'sub-3'],
      );
    });

    test('as initiator: connects signaling, subscribes, creates offer and publishes', () async {
      // `outgoingHandshake` não-nulo é o sinal de que somos o iniciador —
      // reaproveitado de `Core.ensureSession` para também decidir quem
      // oferta o SDP (ver o doc-comment de `WebrtcP2PTransport`).
      final initiatorStatus = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([1, 2, 3]),
      );
      final core = _FakeCore(topics: topics, sessionStatus_: initiatorStatus);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );

      await transport.connect();

      expect(signaling.connectCalls, 1);
      expect(signaling.subscribedTopicsCalls.single, topics.subscribeTopics);
      expect(channel.offerCalls, hasLength(1));
      expect(signaling.publishCalls, hasLength(1));

      final published = signaling.publishCalls.single;
      expect(published.key, topics.publishTopic);
      final decoded = _decodeTestPayload(published.value);
      expect(decoded['kind'], 0); // offer
      expect(decoded['sdp'], channel.offerSdpToReturn);

      // Não deveria ter sido chamado como respondedor.
      expect(channel.answerCalls, isEmpty);
    });

    test('as responder: does not create offer; received offer becomes published answer', () async {
      final responderStatus = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: null,
      );
      final core = _FakeCore(topics: topics, sessionStatus_: responderStatus);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );

      await transport.connect();
      expect(channel.offerCalls, isEmpty);

      final offerPayload = Uint8List.fromList([0, ...utf8.encode('v=0 OFFER REMOTA')]);
      signaling.emit(SignalingMessage('sub-1', offerPayload));
      await Future<void>.delayed(Duration.zero);

      expect(channel.answerCalls, ['v=0 OFFER REMOTA']);
      expect(signaling.publishCalls, hasLength(1));
      final decoded = _decodeTestPayload(signaling.publishCalls.single.value);
      expect(decoded['kind'], 1); // answer
      expect(decoded['sdp'], channel.answerSdpToReturn);
    });

    test('received remote answer calls applyRemoteAnswer', () async {
      final initiatorStatus = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([1]),
      );
      final core = _FakeCore(topics: topics, sessionStatus_: initiatorStatus);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );
      await transport.connect();

      final answerPayload = Uint8List.fromList([1, ...utf8.encode('v=0 RESPOSTA REMOTA')]);
      signaling.emit(SignalingMessage('sub-1', answerPayload));
      await Future<void>.delayed(Duration.zero);

      expect(channel.remoteAnswerCalls, ['v=0 RESPOSTA REMOTA']);
    });

    test('local ICE candidate is published; received remote candidate is applied', () async {
      final initiatorStatus = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([1]),
      );
      final core = _FakeCore(topics: topics, sessionStatus_: initiatorStatus);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );
      await transport.connect();
      signaling.publishCalls.clear(); // limpa a publicação da oferta

      channel.emitLocalCandidate(RTCIceCandidate('candidate:1 local', 'mid0', 0));
      await Future<void>.delayed(Duration.zero);

      expect(signaling.publishCalls, hasLength(1));
      final decoded = _decodeTestPayload(signaling.publishCalls.single.value);
      expect(decoded['kind'], 2); // ice candidate
      expect(decoded['candidate'], 'candidate:1 local');
      expect(decoded['sdpMid'], 'mid0');
      expect(decoded['sdpMLineIndex'], 0);

      final remoteCandidatePayload = Uint8List.fromList([
        2,
        ...utf8.encode(jsonEncode({
          'candidate': 'candidate:2 remoto',
          'sdpMid': 'mid1',
          'sdpMLineIndex': 1,
        })),
      ]);
      signaling.emit(SignalingMessage('sub-1', Uint8List.fromList([1, ...utf8.encode('v=0 ANSWER')])));
      signaling.emit(SignalingMessage('sub-1', remoteCandidatePayload));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(channel.remoteCandidateCalls, [
        {'candidate': 'candidate:2 remoto', 'sdpMid': 'mid1', 'sdpMLineIndex': 1},
      ]);
    });

    test('remote candidate arriving before the offer is held and applied after it, once', () async {
      final responderStatus = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: null,
      );
      final core = _FakeCore(topics: topics, sessionStatus_: responderStatus);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();
      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );
      await transport.connect();

      final candidate = Uint8List.fromList([
        2,
        ...utf8.encode(jsonEncode({'candidate': 'candidate:9 cedo', 'sdpMid': '0', 'sdpMLineIndex': 0})),
      ]);
      // Republicação (§8.2): o respondedor entra no tópico no meio de uma
      // rodada e recebe o candidato antes da oferta, e depois tudo de novo.
      signaling.emit(SignalingMessage('sub-1', candidate));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(channel.remoteCandidateCalls, isEmpty);

      signaling.emit(SignalingMessage('sub-1', Uint8List.fromList([0, ...utf8.encode('v=0 OFFER')])));
      signaling.emit(SignalingMessage('sub-1', candidate));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(channel.answerCalls, ['v=0 OFFER']);
      expect(channel.remoteCandidateCalls, [
        {'candidate': 'candidate:9 cedo', 'sdpMid': '0', 'sdpMLineIndex': 0},
      ]);
      await transport.close();
    });

    test('disconnects signaling as soon as transport becomes connected', () async {
      final status = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([1]),
      );
      final core = _FakeCore(topics: topics, sessionStatus_: status);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );
      await transport.connect();
      expect(signaling.disconnectCalls, 0);

      channel.emitConnectionEvent(const TransportConnectionEvent(TransportConnectionState.connected));
      await Future<void>.delayed(Duration.zero);

      expect(signaling.disconnectCalls, 1);
    });

    test('undecryptable signaling payload (Ok(None)) is ignored without error', () async {
      final status = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: null,
      );
      final core = _FakeCore(topics: topics, sessionStatus_: status)
        ..openSignalingPayloadHandler = (_) => null;
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );
      await transport.connect();

      signaling.emit(SignalingMessage('sub-1', Uint8List(1024)));
      await Future<void>.delayed(Duration.zero);

      expect(channel.answerCalls, isEmpty);
      expect(channel.remoteAnswerCalls, isEmpty);
      expect(channel.remoteCandidateCalls, isEmpty);
    });

    test('send/sendFile/incoming/incomingFile/connectionEvents proxy directly to channel', () async {
      final status = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([1]),
      );
      final core = _FakeCore(topics: topics, sessionStatus_: status);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );

      final received = <Uint8List>[];
      transport.incoming.listen(received.add);
      final receivedFile = <Uint8List>[];
      transport.incomingFile.listen(receivedFile.add);
      final events = <TransportConnectionEvent>[];
      transport.connectionEvents.listen(events.add);

      await transport.send(Uint8List.fromList([9, 9, 9]));
      expect(channel.sendCalls, [Uint8List.fromList([9, 9, 9])]);

      await transport.sendFile(Uint8List.fromList([4, 4]));
      expect(channel.sendFileCalls, [Uint8List.fromList([4, 4])]);

      channel.emitIncoming(Uint8List.fromList([7, 7]));
      channel.emitIncomingFile(Uint8List.fromList([8, 8]));
      channel.emitConnectionEvent(const TransportConnectionEvent(TransportConnectionState.failed));
      await Future<void>.delayed(Duration.zero);

      expect(received, [Uint8List.fromList([7, 7])]);
      expect(receivedFile, [Uint8List.fromList([8, 8])]);
      expect(events, [const TransportConnectionEvent(TransportConnectionState.failed)]);
    });

    test('close() closes signaling and channel', () async {
      final status = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([1]),
      );
      final core = _FakeCore(topics: topics, sessionStatus_: status);
      final channel = _FakeRawP2PChannel();
      final signaling = _FakeSignalingBackend();

      final transport = WebrtcP2PTransport(
        core: core,
        contactId: contact,
        webrtcTransport: channel,
        signalingBackend: signaling,
      );
      await transport.connect();
      await transport.close();

      expect(channel.closed, isTrue);
      expect(signaling.disconnectCalls, 1);
    });

    group('republication (protocol.md §8.2)', () {
      const refresh = Duration(milliseconds: 20);

      SessionStatusDto status({required bool offerer}) => SessionStatusDto(
            state: SessionStateKind.handshaking,
            needsRehandshake: false,
            outgoingHandshake: offerer ? Uint8List.fromList([1]) : null,
          );

      int countKind(_FakeSignalingBackend signaling, int kind) => signaling.publishCalls
          .where((call) => _decodeTestPayload(call.value)['kind'] == kind)
          .length;

      test('offerer republishes offer and candidates until the answer arrives', () async {
        final core = _FakeCore(topics: topics, sessionStatus_: status(offerer: true));
        final channel = _FakeRawP2PChannel();
        final signaling = _FakeSignalingBackend();
        final transport = WebrtcP2PTransport(
          core: core,
          contactId: contact,
          webrtcTransport: channel,
          signalingBackend: signaling,
          signalingRefreshInterval: refresh,
        );

        await transport.connect();
        channel.emitLocalCandidate(RTCIceCandidate('candidate:1 local', 'mid0', 0));
        await Future<void>.delayed(refresh * 4);

        // O par pode não estar inscrito quando a primeira oferta sai (QoS 0, sem retain).
        expect(countKind(signaling, 0), greaterThan(1));
        expect(countKind(signaling, 2), greaterThan(1));
        expect(channel.offerCalls, hasLength(1), reason: 'republica a mesma SDP, sem renegociar');

        signaling.emit(SignalingMessage('sub-1', Uint8List.fromList([1, ...utf8.encode('v=0 ANSWER')])));
        await Future<void>.delayed(refresh);
        final offersAfterAnswer = countKind(signaling, 0);
        await Future<void>.delayed(refresh * 4);

        expect(countKind(signaling, 0), offersAfterAnswer);
        await transport.close();
      });

      test('duplicate answer is applied only once', () async {
        final core = _FakeCore(topics: topics, sessionStatus_: status(offerer: true));
        final channel = _FakeRawP2PChannel();
        final signaling = _FakeSignalingBackend();
        final transport = WebrtcP2PTransport(
          core: core,
          contactId: contact,
          webrtcTransport: channel,
          signalingBackend: signaling,
          signalingRefreshInterval: refresh,
        );
        await transport.connect();

        final answer = Uint8List.fromList([1, ...utf8.encode('v=0 ANSWER')]);
        signaling.emit(SignalingMessage('sub-1', answer));
        signaling.emit(SignalingMessage('sub-1', answer));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(channel.remoteAnswerCalls, hasLength(1));
        await transport.close();
      });

      test('responder answers a repeated offer with the cached answer instead of renegotiating', () async {
        final core = _FakeCore(topics: topics, sessionStatus_: status(offerer: false));
        final channel = _FakeRawP2PChannel();
        final signaling = _FakeSignalingBackend();
        final transport = WebrtcP2PTransport(
          core: core,
          contactId: contact,
          webrtcTransport: channel,
          signalingBackend: signaling,
          signalingRefreshInterval: refresh,
        );
        await transport.connect();

        final offer = Uint8List.fromList([0, ...utf8.encode('v=0 OFFER REMOTA')]);
        signaling.emit(SignalingMessage('sub-1', offer));
        await Future<void>.delayed(Duration.zero);
        signaling.emit(SignalingMessage('sub-1', offer));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(channel.answerCalls, hasLength(1));
        expect(countKind(signaling, 1), 2);
        await transport.close();
      });

      test('stops refreshing signaling once the data channel connects', () async {
        final core = _FakeCore(topics: topics, sessionStatus_: status(offerer: true));
        final channel = _FakeRawP2PChannel();
        final signaling = _FakeSignalingBackend();
        final transport = WebrtcP2PTransport(
          core: core,
          contactId: contact,
          webrtcTransport: channel,
          signalingBackend: signaling,
          signalingRefreshInterval: refresh,
        );
        await transport.connect();

        channel.emitConnectionEvent(const TransportConnectionEvent(TransportConnectionState.connected));
        await Future<void>.delayed(Duration.zero);
        final publishesAtConnect = signaling.publishCalls.length;
        await Future<void>.delayed(refresh * 4);

        expect(signaling.publishCalls.length, publishesAtConnect);
        await transport.close();
      });
    });
  });
}
