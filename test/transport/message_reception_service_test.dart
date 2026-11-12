import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/message_reception_service.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/transfer_foreground_service.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

import '../support/fake_session_events.dart';

class _FakeP2PTransport implements P2PTransport {
  var connectCalls = 0;
  var closeCalls = 0;
  final sendCalls = <Uint8List>[];
  final sendFileCalls = <Uint8List>[];
  bool Function(Uint8List)? sendError;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Future<void> connect() async => connectCalls++;

  @override
  Future<void> send(Uint8List envelope) async {
    if (sendError != null && sendError!(envelope)) throw StateError('envio falhou');
    sendCalls.add(envelope);
  }

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
  void emitConnectionEvent(TransportConnectionEvent event) => _connectionEvents.add(event);
}

class _FakeReceptionCore with FakeSessionEvents, FakeTransferEvents implements Core {
  _FakeReceptionCore() {
    peerDeviceId = List.generate(16, (i) => i);
  }

  Uint8List? outgoingHandshake;

  List<ContactDto> contacts = [];
  final feedHandshakeCalls = <Uint8List>[];
  final decryptIncomingCalls = <Uint8List>[];
  final markSentCalls = <int>[];
  final requeueCalls = <int>[];
  var failMarkSent = false;
  final finishReceiveFileCalls = <Uint8List>[];
  final finishReceiveAudioCalls = <Uint8List>[];

  Uint8List? feedHandshakeResponse;
  var establishOnFeedHandshake = false;
  IncomingMessageDto? Function(Uint8List)? decryptIncomingHandler;
  List<SealedMessageDto> pendingToFlush = [];
  List<FileOfferDto> pendingOffers = [];
  IngestedChunkDto? Function(Uint8List)? ingestWireChunkHandler;
  var fileFeedbackCalls = 0;
  TransferProgressDto? receiveProgress;

  @override
  Future<Uint8List> fileFeedback({
    required List<int> peerDeviceId,
    required List<int> fileId,
  }) async {
    fileFeedbackCalls++;
    return Uint8List.fromList([0xFB]);
  }

  @override
  Future<TransferProgressDto?> transferProgress({required List<int> fileId}) async => receiveProgress;

  @override
  Future<List<ContactDto>> listContacts() async => contacts;

  @override
  Future<SessionStatusDto> resetSession({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

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

  /// Emula o roteamento que o Rust faz em `receiveIncoming`: com a sessão em
  /// handshake os bytes vão para [feedHandshake]; estabelecida, para
  /// [decryptIncoming]; falha, para lugar nenhum. Os dois são só ganchos do
  /// dublê, o `Core` real não os expõe.
  @override
  Future<IncomingResultDto> receiveIncoming({
    required List<int> peerDeviceId,
    required List<int> bytes,
  }) async {
    switch (sessionState) {
      case SessionStateKind.failed:
        return const IncomingResultDto();
      case SessionStateKind.handshaking:
        return IncomingResultDto(
          reply: await feedHandshake(peerDeviceId: peerDeviceId, bytes: bytes),
        );
      case SessionStateKind.established:
        return IncomingResultDto(
          message: await decryptIncoming(peerDeviceId: peerDeviceId, envelope: bytes),
          reply: replyWhenEstablished,
        );
    }
  }

  /// Resposta que o Rust devolveria com a sessão estabelecida: a RESP de uma
  /// reabertura do par, ou o anúncio de suítes (§11.4).
  Uint8List? replyWhenEstablished;

  final connectSignalCalls = <List<int>>[];

  /// Bytes que `connectSignal` devolve; sem valor, a INIT pendente enquanto em
  /// handshake.
  Uint8List? connectSignalResult;

  @override
  Future<Uint8List?> connectSignal({required List<int> peerDeviceId}) async {
    connectSignalCalls.add(peerDeviceId);
    return connectSignalResult ??
        (sessionState == SessionStateKind.handshaking ? outgoingHandshake : null);
  }

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

  /// Como o Rust com uma candidata recente: a fila não sai.
  var holdQueue = false;

  @override
  Future<List<SealedMessageDto>> flushPending({required List<int> peerDeviceId}) async {
    if (holdQueue) return [];
    final list = List<SealedMessageDto>.from(pendingToFlush);
    pendingToFlush.clear();
    return list;
  }

  @override
  Future<void> markMessageSent({required int messageId}) async {
    markSentCalls.add(messageId);
    if (failMarkSent) throw StateError('banco indisponível');
  }

  @override
  Future<void> requeueMessage({required int messageId}) async {
    requeueCalls.add(messageId);
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
  TestWidgetsFlutterBinding.ensureInitialized();

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
      expect(events.whereType<SessionStateChangedEvent>(), isNotEmpty);

      await sub.cancel();
    });

    test('reply returned with an established session is sent back to the peer', () async {
      core.sessionState = SessionStateKind.established;
      core.replyWhenEstablished = Uint8List.fromList([5, 5]);
      await service.start();

      transport.emitIncoming(Uint8List.fromList([1, 2, 3]));
      await pumpEventQueue();

      expect(transport.sendCalls.first, Uint8List.fromList([5, 5]));
    });

    test('channel opening publishes the connect signal', () async {
      core.sessionState = SessionStateKind.handshaking;
      core.connectSignalResult = Uint8List.fromList([9, 9]);
      await service.start();
      await pumpEventQueue();

      expect(core.connectSignalCalls, isNotEmpty);
      expect(transport.sendCalls.any((b) => listEquals(b, [9, 9])), isTrue);
    });

    test('session replaced by the peer flushes pending even if it stays established', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();
      await pumpEventQueue();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 8, bytes: Uint8List.fromList([88])),
      ];

      core.generation = 1;
      await pumpEventQueue();

      expect(transport.sendCalls.where((b) => listEquals(b, [88])), hasLength(1));
      expect(service.sessionStateFor(contact)?.generation, 1);
    });

    test('a renewal that expires without confirmation drains the queue after the hold', () async {
      core.sessionState = SessionStateKind.established;
      final held = MessageReceptionService(
        core: core,
        router: router,
        renewalHold: const Duration(milliseconds: 50),
      );
      addTearDown(held.dispose);
      await held.start();
      await pumpEventQueue();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 9, bytes: Uint8List.fromList([90])),
      ];

      core.holdQueue = true;
      core.renewing = true;
      await pumpEventQueue();
      expect(transport.sendCalls.where((b) => listEquals(b, [90])), isEmpty);

      // A candidata passa do prazo sem confirmar: o Rust não avisa ninguém.
      core.holdQueue = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(transport.sendCalls.where((b) => listEquals(b, [90])), hasLength(1));
    });

    test('the end of a renewal reported by any event drains the queue', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();
      await pumpEventQueue();
      core.holdQueue = true;
      core.renewing = true;
      await pumpEventQueue();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 11, bytes: Uint8List.fromList([110])),
      ];

      // Alguma chamada depois do prazo publica `renewing` falso antes do timer.
      core.holdQueue = false;
      core.renewing = false;
      await pumpEventQueue();

      expect(transport.sendCalls.where((b) => listEquals(b, [110])), hasLength(1));
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

    test('responder pending flushed after first message', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();
      await pumpEventQueue();
      // O respondedor selou a mensagem antes de existir cadeia de envio: a
      // fila só rende bytes depois que o pacote do iniciador chega.
      core.pendingToFlush = [
        SealedMessageDto(messageId: 7, bytes: Uint8List.fromList([77, 77])),
      ];

      transport.emitIncoming(Uint8List.fromList([1, 2, 3]));
      await pumpEventQueue();

      expect(transport.sendCalls.where((b) => listEquals(b, [77, 77])), hasLength(1));
      expect(core.markSentCalls, [7]);
    });

    test('responder pending flushed after a typing packet creates the chain', () async {
      core.sessionState = SessionStateKind.established;
      core.decryptIncomingHandler = (_) => IncomingMessageDto(
            messageId: null,
            body: '',
            isTyping: true,
            receivedAtUnixSecs: 1000,
          );
      await service.start();
      await pumpEventQueue();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 8, bytes: Uint8List.fromList([88])),
      ];

      transport.emitIncoming(Uint8List.fromList([4]));
      await pumpEventQueue();

      expect(core.markSentCalls, [8]);
    });

    test('session that becomes established after start flushes pending', () async {
      await service.start();
      await pumpEventQueue();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 9, bytes: Uint8List.fromList([9, 9])),
      ];

      core.sessionState = SessionStateKind.established;
      await pumpEventQueue();

      expect(transport.sendCalls.any((b) => listEquals(b, [9, 9])), isTrue);
      expect(core.markSentCalls, [9]);
    });

    test('republishes the Rust session state as SessionStateChangedEvent', () async {
      await service.start();
      final events = <SessionStateChangedEvent>[];
      final sub = service
          .eventsFor(contact)
          .where((e) => e is SessionStateChangedEvent)
          .cast<SessionStateChangedEvent>()
          .listen(events.add);

      core.sessionState = SessionStateKind.failed;
      await pumpEventQueue();

      expect(events.last.state, SessionStateKind.failed);
      expect(service.sessionStateFor(contact)?.state, SessionStateKind.failed);
      await sub.cancel();
    });

    test('republishes Rust offer events as OffersChangedEvent for the right contact', () async {
      await service.start();
      final events = <OffersChangedEvent>[];
      final sub = service.events.where((e) => e is OffersChangedEvent).cast<OffersChangedEvent>().listen(events.add);
      final fileId = Uint8List.fromList(List.filled(16, 4));

      core.emitTransferEvent(TransferEventDto(
        peerDeviceId: Uint8List.fromList(contact.deviceId),
        fileId: fileId,
        kind: TransferEventKind.offerAppeared,
      ));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.contactId, contact);
      expect(events.single.fileId, fileId);
      expect(events.single.kind, TransferEventKind.offerAppeared);
      await sub.cancel();
    });

    test('packets arriving on a failed session are dropped, not fed as handshake', () async {
      await service.start();
      core.sessionState = SessionStateKind.failed;
      await pumpEventQueue();

      transport.emitIncoming(Uint8List.fromList([1, 2, 3]));
      await pumpEventQueue();

      expect(core.feedHandshakeCalls, isEmpty);
      expect(core.decryptIncomingCalls, isEmpty);
    });

    test('sessions dropped by lock flush pending again when re-established', () async {
      await service.start();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 1, bytes: Uint8List.fromList([1])),
      ];
      core.sessionState = SessionStateKind.established;
      await pumpEventQueue();
      expect(core.markSentCalls, [1]);

      core.dropSession();
      await pumpEventQueue();
      expect(service.sessionStateFor(contact)?.state, isNull);

      core.pendingToFlush = [
        SealedMessageDto(messageId: 2, bytes: Uint8List.fromList([2])),
      ];
      core.sessionState = SessionStateKind.established;
      await pumpEventQueue();

      expect(core.markSentCalls, [1, 2]);
    });

    test('flush does not duplicate', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();
      await pumpEventQueue();
      core.pendingToFlush = [
        SealedMessageDto(messageId: 5, bytes: Uint8List.fromList([55, 55])),
      ];

      transport.emitIncoming(Uint8List.fromList([1]));
      transport.emitIncoming(Uint8List.fromList([2]));
      await pumpEventQueue();

      expect(transport.sendCalls.where((b) => listEquals(b, [55, 55])), hasLength(1));
      expect(core.markSentCalls, [5]);
    });

    test('failed flush send requeues the failed message and the unsent rest', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();
      await pumpEventQueue();
      transport.sendError = (b) => listEquals(b, [2]);
      core.pendingToFlush = [
        SealedMessageDto(messageId: 1, bytes: Uint8List.fromList([1])),
        SealedMessageDto(messageId: 2, bytes: Uint8List.fromList([2])),
        SealedMessageDto(messageId: 3, bytes: Uint8List.fromList([3])),
      ];

      transport.emitIncoming(Uint8List.fromList([9]));
      await pumpEventQueue();

      expect(core.markSentCalls, [1]);
      expect(core.requeueCalls, [2, 3]);
    });

    test('failed markMessageSent requeues the rest of the batch but not the delivered message', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();
      await pumpEventQueue();
      core.failMarkSent = true;
      core.pendingToFlush = [
        SealedMessageDto(messageId: 1, bytes: Uint8List.fromList([1])),
        SealedMessageDto(messageId: 2, bytes: Uint8List.fromList([2])),
      ];

      transport.emitIncoming(Uint8List.fromList([9]));
      await pumpEventQueue();

      expect(transport.sendCalls.where((b) => listEquals(b, [1])), hasLength(1));
      expect(core.requeueCalls, [2], reason: 'a 1 já saiu; reenfileirá-la a enviaria duas vezes');
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

    test('completing voice note transfer caches compressed audio and emits VoiceNoteReceivedEvent', () async {
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
      expect(service.getVoiceNoteAudio(fileId), Uint8List.fromList([1, 2, 3]));
      expect(events.whereType<VoiceNoteReceivedEvent>(), hasLength(1));

      await sub.cancel();
    });

    group('FILE_FEEDBACK cadence', () {
      final fileId = Uint8List.fromList(List.filled(16, 7));
      TransferProgressDto progress({required int blocksDone, bool isComplete = false}) =>
          TransferProgressDto(
            blocksDone: blocksDone,
            totalBlocks: 4,
            bytesDone: BigInt.zero,
            isComplete: isComplete,
          );

      // Encerra pelo caminho normal: sem isso o timer periódico sobrevive ao fakeAsync.
      void stopCadence(FakeAsync async) {
        core.receiveProgress = null;
        async.elapse(const Duration(milliseconds: 500));
        expect(async.periodicTimerCount, 0);
      }

      test('keeps sending every 500 ms with no chunks arriving, which is what wakes an exhausted sender', () {
        fakeAsync((async) {
          core.receiveProgress = progress(blocksDone: 0);
          router.incomingFor(contact);

          unawaited(service.watchIncomingTransfer(contact, fileId));
          async.flushMicrotasks();
          expect(core.fileFeedbackCalls, 1, reason: 'o primeiro vai no aceite, sem esperar o timer');

          async.elapse(const Duration(milliseconds: 1500));
          expect(core.fileFeedbackCalls, 4);
          expect(transport.sendCalls, hasLength(4));

          stopCadence(async);
        });
      });

      test('first chunk starts the cadence of a transfer that was auto-accepted', () {
        fakeAsync((async) {
          core.receiveProgress = progress(blocksDone: 0);
          core.ingestWireChunkHandler = (_) =>
              IngestedChunkDto(fileId: fileId, progress: progress(blocksDone: 0));
          unawaited(service.start());
          async.flushMicrotasks();

          transport.emitIncomingFile(Uint8List.fromList([1]));
          async.flushMicrotasks();
          expect(core.fileFeedbackCalls, 1);

          async.elapse(const Duration(milliseconds: 500));
          expect(core.fileFeedbackCalls, 2);

          stopCadence(async);
        });
      });

      test('completed block is reported at once, without waiting for the tick', () {
        fakeAsync((async) {
          core.receiveProgress = progress(blocksDone: 0);
          var blocksDone = 0;
          core.ingestWireChunkHandler = (_) =>
              IngestedChunkDto(fileId: fileId, progress: progress(blocksDone: blocksDone));
          unawaited(service.start());
          async.flushMicrotasks();
          transport.emitIncomingFile(Uint8List.fromList([1]));
          async.flushMicrotasks();
          expect(core.fileFeedbackCalls, 1);

          transport.emitIncomingFile(Uint8List.fromList([2]));
          async.flushMicrotasks();
          expect(core.fileFeedbackCalls, 1, reason: 'mesmo bloco: fica para o tick');

          blocksDone = 1;
          transport.emitIncomingFile(Uint8List.fromList([3]));
          async.flushMicrotasks();
          expect(core.fileFeedbackCalls, 2);

          stopCadence(async);
        });
      });

      test('stops when the transfer ends or disappears', () {
        fakeAsync((async) {
          core.receiveProgress = progress(blocksDone: 0);
          router.incomingFor(contact);
          unawaited(service.watchIncomingTransfer(contact, fileId));
          async.flushMicrotasks();

          core.receiveProgress = null;
          async.elapse(const Duration(seconds: 5));

          expect(core.fileFeedbackCalls, 1);
          expect(async.periodicTimerCount, 0);
        });
      });

      test('does not recreate a forgotten transport while the peer is offline', () {
        fakeAsync((async) {
          core.receiveProgress = progress(blocksDone: 0);
          router.incomingFor(contact);
          unawaited(service.watchIncomingTransfer(contact, fileId));
          async.flushMicrotasks();

          unawaited(router.closeContact(contact));
          async.flushMicrotasks();
          final connectsBefore = transport.connectCalls;

          async.elapse(const Duration(seconds: 2));

          expect(core.fileFeedbackCalls, 1);
          expect(transport.connectCalls, connectsBefore);

          stopCadence(async);
        });
      });
    });

    group('foreground service while receiving a file', () {
      const channel = MethodChannel('viska/transfer_service');
      late List<String> serviceCalls;
      final fileId = Uint8List.fromList(List.filled(16, 9));

      TransferProgressDto progress({required bool complete}) => TransferProgressDto(
            blocksDone: complete ? 1 : 0,
            totalBlocks: 1,
            bytesDone: BigInt.from(10),
            isComplete: complete,
          );

      setUp(() {
        serviceCalls = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          serviceCalls.add(call.method);
          return null;
        });
        service = MessageReceptionService(
          core: core,
          router: router,
          tempDirProvider: () async => tempDir.path,
          foregroundService: TransferForegroundService(channel: channel, enabled: true),
        );
        core.sessionState = SessionStateKind.established;
        core.pendingOffers = [];
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      test('holds the service from the first chunk until the file completes', () async {
        var complete = false;
        core.ingestWireChunkHandler =
            (_) => IngestedChunkDto(fileId: fileId, progress: progress(complete: complete));
        core.receiveProgress = progress(complete: false);
        await service.start();

        transport.emitIncomingFile(Uint8List.fromList([1]));
        await pumpEventQueue();
        transport.emitIncomingFile(Uint8List.fromList([2]));
        await pumpEventQueue();
        expect(serviceCalls, ['start'], reason: 'um recebimento só sobe o serviço uma vez');

        complete = true;
        transport.emitIncomingFile(Uint8List.fromList([3]));
        await pumpEventQueue();
        expect(serviceCalls, ['start', 'stop']);
      });

      test('gives the service back when the sender goes silent', () {
        fakeAsync((async) {
          core.ingestWireChunkHandler =
              (_) => IngestedChunkDto(fileId: fileId, progress: progress(complete: false));
          core.receiveProgress = progress(complete: false);
          unawaited(service.start());
          async.flushMicrotasks();

          transport.emitIncomingFile(Uint8List.fromList([1]));
          async.flushMicrotasks();
          expect(serviceCalls, ['start']);

          async.elapse(const Duration(seconds: 61));
          async.flushMicrotasks();
          expect(serviceCalls, ['start', 'stop']);
        });
      });
    });

    group('app lifecycle', () {
      late List<_FakeP2PTransport> created;

      setUp(() {
        created = [];
        router = P2PTransportRouter(
          core: core,
          transportFactory: (_, _) {
            final next = _FakeP2PTransport();
            created.add(next);
            return next;
          },
        );
        service = MessageReceptionService(
          core: core,
          router: router,
          tempDirProvider: () async => tempDir.path,
        );
      });

      test('reconnects on resume', () async {
        await service.start();
        expect(created, hasLength(1));

        created.first.emitConnectionEvent(
          const TransportConnectionEvent(TransportConnectionState.failed, reason: 'socket caiu'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(created, hasLength(1), reason: 'a nova tentativa automática só vem depois do atraso');

        service.handleAppResumed();
        await Future<void>.delayed(Duration.zero);

        expect(created, hasLength(2), reason: 'voltar do seletor não espera o atraso da nova tentativa');
      });

      test('resume keeps live transport', () async {
        await service.start();

        service.handleAppResumed();
        await Future<void>.delayed(Duration.zero);

        expect(created, hasLength(1));
        expect(created.single.closeCalls, 0);
      });

      test('resume does not reconnect while the app is locked', () async {
        await service.start();
        created.first.emitConnectionEvent(
          const TransportConnectionEvent(TransportConnectionState.failed, reason: 'socket caiu'),
        );
        await Future<void>.delayed(Duration.zero);
        service.pause();

        service.handleAppResumed();
        await Future<void>.delayed(Duration.zero);

        expect(created, hasLength(1), reason: 'o desbloqueio ressincroniza os contatos');
      });
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
