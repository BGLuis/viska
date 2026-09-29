import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/message_reception_service.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

class _FakeP2PTransport implements P2PTransport {
  var connectCalls = 0;
  var closeCalls = 0;
  final sendCalls = <Uint8List>[];
  final sendFileCalls = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Future<void> connect() async => connectCalls++;

  @override
  Future<void> send(Uint8List envelope) async => sendCalls.add(envelope);

  @override
  Future<void> sendFile(Uint8List bytes) async => sendFileCalls.add(bytes);

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;

  @override
  Future<void> close() async => closeCalls++;

  void emitIncoming(Uint8List bytes) => _incoming.add(bytes);
  void emitIncomingFile(Uint8List bytes) => _incomingFile.add(bytes);
}

class _FakeReceptionCore implements Core {
  SessionStateKind sessionState = SessionStateKind.handshaking;
  Uint8List? outgoingHandshake;

  List<ContactDto> contacts = [];
  final feedHandshakeCalls = <Uint8List>[];
  final decryptIncomingCalls = <Uint8List>[];
  final markSentCalls = <int>[];
  final finishReceiveFileCalls = <Uint8List>[];
  final finishReceiveAudioCalls = <Uint8List>[];

  Uint8List? feedHandshakeResponse;
  var establishOnFeedHandshake = false;
  IncomingMessageDto? Function(Uint8List)? decryptIncomingHandler;
  List<SealedMessageDto> pendingToFlush = [];
  List<FileOfferDto> pendingOffers = [];
  IngestedChunkDto? Function(Uint8List)? ingestWireChunkHandler;

  @override
  Future<List<ContactDto>> listContacts() async => contacts;

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: sessionState,
        needsRehandshake: false,
        outgoingHandshake: outgoingHandshake,
      );

  @override
  Future<SessionStatusDto?> sessionStatus({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: sessionState,
        needsRehandshake: false,
        outgoingHandshake: outgoingHandshake,
      );

  @override
  Future<Uint8List?> feedHandshake({
    required List<int> peerDeviceId,
    required List<int> bytes,
  }) async {
    feedHandshakeCalls.add(Uint8List.fromList(bytes));
    if (establishOnFeedHandshake) {
      sessionState = SessionStateKind.established;
      outgoingHandshake = null;
    }
    return feedHandshakeResponse;
  }

  @override
  Future<IncomingMessageDto?> decryptIncoming({
    required List<int> peerDeviceId,
    required List<int> envelope,
  }) async {
    final bytes = Uint8List.fromList(envelope);
    decryptIncomingCalls.add(bytes);
    if (decryptIncomingHandler != null) {
      return decryptIncomingHandler!(bytes);
    }
    return IncomingMessageDto(
      messageId: 42,
      body: 'Decifrado com sucesso',
      isTyping: false,
      receivedAtUnixSecs: 1000,
    );
  }

  @override
  Future<List<SealedMessageDto>> flushPending({required List<int> peerDeviceId}) async {
    final list = List<SealedMessageDto>.from(pendingToFlush);
    pendingToFlush.clear();
    return list;
  }

  @override
  Future<void> markMessageSent({required int messageId}) async {
    markSentCalls.add(messageId);
  }

  @override
  Future<IngestedChunkDto?> ingestIncomingWireBytes({required List<int> wireBytes}) async {
    if (ingestWireChunkHandler != null) {
      return ingestWireChunkHandler!(Uint8List.fromList(wireBytes));
    }
    return null;
  }

  @override
  Future<List<FileOfferDto>> pendingFileOffers({required List<int> peerDeviceId}) async =>
      pendingOffers;

  @override
  Future<Uint8List> finishReceiveFile({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) async {
    finishReceiveFileCalls.add(Uint8List.fromList(fileId));
    return Uint8List.fromList([0xAA, 0xBB]); // FILE_COMPLETE selado
  }

  @override
  Future<Uint8List> finishReceiveAudio({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) async {
    finishReceiveAudioCalls.add(Uint8List.fromList(fileId));
    // Cria arquivo simulado para que decodeAudioToWav possa ler
    File(destinationPath).writeAsBytesSync([1, 2, 3]);
    return Uint8List.fromList([0xCC, 0xDD]); // FILE_COMPLETE selado
  }

  @override
  Future<Uint8List> decodeAudioToWav({required List<int> internalBytes}) async {
    return Uint8List.fromList([0x57, 0x41, 0x56]); // 'WAV'
  }

  final sealOutgoingReceiptCalls = <String>[];

  @override
  Future<SealedMessageDto> sealOutgoingReceipt({
    required List<int> peerDeviceId,
    required String targetId,
  }) async {
    sealOutgoingReceiptCalls.add(targetId);
    return SealedMessageDto(
      messageId: 0,
      bytes: Uint8List.fromList([0x11, 1, 2, 3]),
    );
  }

  @override
  Future<void> markMessageDelivered({required int messageId}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('MessageReceptionService', () {
    late ContactId contact;
    late _FakeReceptionCore core;
    late _FakeP2PTransport transport;
    late P2PTransportRouter router;
    late MessageReceptionService service;
    late Directory tempDir;

    setUp(() {
      contact = ContactId(List.generate(16, (i) => i));
      core = _FakeReceptionCore();
      core.contacts = [
        ContactDto(
          deviceId: contact.deviceId,
          signingPubkey: Uint8List(32),
          dhPubkey: Uint8List(32),
          pairedAtUnixSecs: 1000,
          nickname: 'Alice',
          isVerified: true,
        ),
      ];

      transport = _FakeP2PTransport();
      router = P2PTransportRouter(
        core: core,
        transportFactory: (_, _) => transport,
      );

      tempDir = Directory.systemTemp.createTempSync('viska-reception-test');
      service = MessageReceptionService(
        core: core,
        router: router,
        tempDirProvider: () async => tempDir.path,
      );
    });

    tearDown(() async {
      await service.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('start() syncs contacts and registers listeners', () async {
      await service.start();

      expect(transport.connectCalls, 1);
    });

    test('decrypts incoming text message and emits MessageReceivedEvent', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();

      final events = <MessageReceptionEvent>[];
      final sub = service.eventsFor(contact).listen(events.add);

      transport.emitIncoming(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);

      expect(core.decryptIncomingCalls, [Uint8List.fromList([1, 2, 3])]);
      expect(events, hasLength(1));
      expect(events.first, isA<MessageReceivedEvent>());
      final received = events.first as MessageReceivedEvent;
      expect(received.message?.body, 'Decifrado com sucesso');
      expect(core.sealOutgoingReceiptCalls, ['42']);
      expect(transport.sendCalls, [Uint8List.fromList([0x11, 1, 2, 3])]);

      await sub.cancel();
    });

    test('ephemeral typing indicator emits TypingIndicatorEvent and not MessageReceivedEvent', () async {
      core.sessionState = SessionStateKind.established;
      core.decryptIncomingHandler = (_) => IncomingMessageDto(
            messageId: null,
            body: '',
            isTyping: true,
            receivedAtUnixSecs: 1000,
          );
      await service.start();

      final events = <MessageReceptionEvent>[];
      final sub = service.eventsFor(contact).listen(events.add);

      transport.emitIncoming(Uint8List.fromList([4, 5, 6]));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<TypingIndicatorEvent>());

      await sub.cancel();
    });

    test('incoming handshake feeds feedHandshake and sends RESP if generated', () async {
      core.sessionState = SessionStateKind.handshaking;
      core.feedHandshakeResponse = Uint8List.fromList([7, 7, 7]);
      core.establishOnFeedHandshake = true;
      await service.start();

      final events = <MessageReceptionEvent>[];
      final sub = service.eventsFor(contact).listen(events.add);

      transport.emitIncoming(Uint8List.fromList([1, 1]));
      await Future<void>.delayed(Duration.zero);

      expect(core.feedHandshakeCalls, [Uint8List.fromList([1, 1])]);
      expect(transport.sendCalls, [Uint8List.fromList([7, 7, 7])]);
      expect(events.whereType<SessionEstablishedEvent>(), isNotEmpty);

      await sub.cancel();
    });

    test('handshake completion flushes pending messages and marks them sent', () async {
      core.sessionState = SessionStateKind.handshaking;
      core.establishOnFeedHandshake = true;
      core.pendingToFlush = [
        SealedMessageDto(
          messageId: 101,
          bytes: Uint8List.fromList([99, 99]),
        ),
      ];
      await service.start();

      transport.emitIncoming(Uint8List.fromList([1]));
      await pumpEventQueue();

      expect(transport.sendCalls.any((b) => listEquals(b, [99, 99])), isTrue);
      expect(core.markSentCalls, [101]);
    });

    test('completing generic file transfer sends FILE_COMPLETE and caches path', () async {
      final fileId = Uint8List.fromList(List.generate(16, (i) => 0xFF));
      core.sessionState = SessionStateKind.established;
      core.pendingOffers = [
        FileOfferDto(
          fileId: fileId,
          name: 'dados.bin',
          fileSize: BigInt.from(100),
        ),
      ];
      core.ingestWireChunkHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(100),
              isComplete: true,
            ),
          );

      await service.start();
      final events = <MessageReceptionEvent>[];
      final sub = service.eventsFor(contact).listen(events.add);

      transport.emitIncomingFile(Uint8List.fromList([0xAA]));
      await pumpEventQueue();

      expect(core.finishReceiveFileCalls, [fileId]);
      expect(transport.sendCalls.any((b) => listEquals(b, [0xAA, 0xBB])), isTrue);
      expect(service.getReceivedFilePath(fileId), isNotNull);
      expect(events.whereType<FileReceivedEvent>(), hasLength(1));

      await sub.cancel();
    });

    test('completing voice note transfer decodes WAV, caches audio, and emits VoiceNoteReceivedEvent', () async {
      final fileId = Uint8List.fromList(List.generate(16, (i) => 0xEE));
      core.sessionState = SessionStateKind.established;
      core.pendingOffers = []; // Não é oferta genérica -> áudio
      core.ingestWireChunkHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(100),
              isComplete: true,
            ),
          );

      await service.start();
      final events = <MessageReceptionEvent>[];
      final sub = service.eventsFor(contact).listen(events.add);

      transport.emitIncomingFile(Uint8List.fromList([0xBB]));
      await pumpEventQueue();

      expect(core.finishReceiveAudioCalls, [fileId]);
      expect(service.isVoiceNoteReady(fileId), isTrue);
      expect(service.getVoiceNoteAudio(fileId), Uint8List.fromList([0x57, 0x41, 0x56]));
      expect(events.whereType<VoiceNoteReceivedEvent>(), hasLength(1));

      await sub.cancel();
    });

    test('pause stops processing and resume re-enables processing', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();

      service.pause();
      transport.emitIncoming(Uint8List.fromList([1, 1, 1]));
      await Future<void>.delayed(Duration.zero);

      expect(core.decryptIncomingCalls, isEmpty, reason: 'não deve processar enquanto pausado');

      service.resume();
      transport.emitIncoming(Uint8List.fromList([2, 2, 2]));
      await Future<void>.delayed(Duration.zero);

      expect(core.decryptIncomingCalls, [Uint8List.fromList([2, 2, 2])]);
    });
  });
}
