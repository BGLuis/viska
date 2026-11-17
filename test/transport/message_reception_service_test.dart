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

class _FakeReceptionCore with FakeSessionEvents, FakeTransferEvents, FakeMessageEvents implements Core {
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

  final markFailedCalls = <int>[];

  @override
  Future<void> markMessageFailed({required int messageId}) async {
    markFailedCalls.add(messageId);
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

  /// Quantas chamadas a `finishReceiveFile` falham antes do commit.
  var finishFailuresLeft = 0;

  /// `null` imita o Rust sem sessão para selar o `FILE_COMPLETE`.
  Uint8List? fileCompleteToReturn = Uint8List.fromList([0xAA, 0xBB]);

  @override
  Future<Uint8List?> finishReceiveFile({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) async {
    finishReceiveFileCalls.add(Uint8List.fromList(fileId));
    if (finishFailuresLeft > 0) {
      finishFailuresLeft--;
      throw StateError('disco cheio');
    }
    File(destinationPath).writeAsBytesSync([7, 7]);
    // Como o Rust: depois do commit a transferência some.
    receiveProgress = null;
    return fileCompleteToReturn;
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

  /// O que `resumeTransfers` devolve, como o Rust depois de reconstruir.
  List<ResumedTransferDto> resumable = [];
  final resumeCalls = <Uint8List>[];

  /// Como o Rust, cada transferência volta uma vez por pedido configurado:
  /// um recebimento abandonado, por exemplo, deixa de existir depois do aviso.
  /// Se definido, cada `resumeTransfers` espera por ele antes de responder.
  Completer<void>? resumeGate;
  var resumesInFlight = 0;
  var maxResumesInFlight = 0;

  @override
  Future<List<ResumedTransferDto>> resumeTransfers({required List<int> peerDeviceId}) async {
    resumesInFlight++;
    if (resumesInFlight > maxResumesInFlight) maxResumesInFlight = resumesInFlight;
    final gate = resumeGate;
    if (gate != null) await gate.future;
    resumesInFlight--;
    resumeCalls.add(Uint8List.fromList(peerDeviceId));
    final out = resumable;
    resumable = [];
    return out;
  }

  /// O que `sealResumedOffer` devolve, e quantas vezes foi chamado.
  Uint8List? offerToSeal;
  var sealOfferCalls = 0;

  @override
  Future<Uint8List?> sealResumedOffer({
    required List<int> peerDeviceId,
    required List<int> fileId,
  }) async {
    sealOfferCalls++;
    return offerToSeal;
  }

  /// Pedaços que o emissor ainda tem a mandar, na ordem.
  final outgoingChunks = <Uint8List>[];
  final nextChunkCalls = <Uint8List>[];

  /// Roda dentro da leitura do emissor: um aviso do Rust que chega justo ali.
  void Function()? onNextChunkRead;

  @override
  Future<Uint8List?> nextOutgoingWireChunk({required List<int> fileId}) async {
    nextChunkCalls.add(Uint8List.fromList(fileId));
    onNextChunkRead?.call();
    return outgoingChunks.isEmpty ? null : outgoingChunks.removeAt(0);
  }

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

    test('decrypts incoming text message and acknowledges it, leaving the timeline to Rust events', () async {
      core.sessionState = SessionStateKind.established;
      await service.start();

      final events = <MessageReceptionEvent>[];
      final sub = service.eventsFor(contact).listen(events.add);

      transport.emitIncoming(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);

      expect(core.decryptIncomingCalls, [Uint8List.fromList([1, 2, 3])]);
      expect(events, isEmpty, reason: 'a linha chega como MessageChangedEvent, não por aqui');
      expect(core.sealOutgoingReceiptCalls, ['42']);
      expect(transport.sendCalls, [Uint8List.fromList([0x11, 1, 2, 3])]);

      await sub.cancel();
    });

    test('ephemeral typing indicator emits only TypingIndicatorEvent', () async {
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

    group('resuming transfers (§7.5)', () {
      final fileId = Uint8List.fromList(List.filled(16, 0xF1));

      ResumedTransferDto send({bool needsOffer = false}) => ResumedTransferDto(
            fileId: fileId,
            direction: ResumedDirectionDto.send,
            needsOffer: needsOffer,
            messageId: 5,
          );

      TransferProgressDto waiting({bool awaitingAnswer = false}) => TransferProgressDto(
            blocksDone: 0,
            totalBlocks: 2,
            bytesDone: BigInt.zero,
            isComplete: false,
            awaitingAnswer: awaitingAnswer,
          );

      test('established session resends the offer, pumps the send and marks it sent', () async {
        core.resumable = [send(needsOffer: true)];
        core.offerToSeal = Uint8List.fromList([0x0F]);
        core.outgoingChunks.addAll([Uint8List.fromList([1]), Uint8List.fromList([2])]);
        core.sessionState = SessionStateKind.established;
        await service.start();
        await pumpEventQueue();

        expect(core.resumeCalls, isNotEmpty);
        expect(transport.sendCalls.where((b) => listEquals(b, [0x0F])), hasLength(1));
        expect(transport.sendFileCalls, [Uint8List.fromList([1]), Uint8List.fromList([2])]);
        expect(core.markSentCalls, contains(5));
      });

      test('a resumed receive starts sending FILE_FEEDBACK again', () async {
        core.resumable = [
          ResumedTransferDto(
            fileId: fileId,
            direction: ResumedDirectionDto.receive,
            needsOffer: false,
          ),
        ];
        core.receiveProgress = TransferProgressDto(
          blocksDone: 1,
          totalBlocks: 2,
          bytesDone: BigInt.from(10),
          isComplete: false, awaitingAnswer: false
        );
        core.sessionState = SessionStateKind.established;
        await service.start();
        await pumpEventQueue();

        expect(core.fileFeedbackCalls, greaterThan(0));
      });

      test('nothing resumes while a renewal holds the queue, and the promotion resumes', () async {
        core.sessionState = SessionStateKind.established;
        core.renewing = true;
        await service.start();
        await pumpEventQueue();
        core.resumeCalls.clear();

        core.renewing = false;
        core.generation = 1;
        await pumpEventQueue();

        expect(core.resumeCalls, isNotEmpty);
      });

      test('a session drop and a new establishment resume again', () async {
        core.sessionState = SessionStateKind.established;
        await service.start();
        await pumpEventQueue();
        final before = core.resumeCalls.length;

        // Bloqueio do cofre: a sessão some e a geração recomeça do zero.
        core.dropSession();
        core.sessionState = SessionStateKind.established;
        await pumpEventQueue();

        expect(core.resumeCalls.length, greaterThan(before));
      });

      test('a resumed send that stops with the transport is marked failed, not sent', () async {
        core.resumable = [send()];
        core.outgoingChunks.add(Uint8List.fromList([1]));
        core.receiveProgress = waiting();
        core.sessionState = SessionStateKind.established;
        await service.start();
        await pumpEventQueue();
        // O emissor espera feedback; o transporte cai nesse meio-tempo. A queda
        // acorda o laço, que não tem nenhum aviso do Rust para esperar.
        final dropped = transport;
        await router.closeContact(contact);
        dropped.emitConnectionEvent(const TransportConnectionEvent(TransportConnectionState.failed));
        await pumpEventQueue();

        expect(core.markSentCalls, isNot(contains(5)));
        expect(core.markFailedCalls, contains(5));
      });

      test('a new channel without a session change resumes too', () async {
        core.sessionState = SessionStateKind.established;
        await service.start();
        await pumpEventQueue();
        final before = core.resumeCalls.length;

        // O transporte caiu e foi recriado; a sessão continua a mesma.
        await router.closeContact(contact);
        transport = _FakeP2PTransport();
        service.ensureListening(contact);
        await pumpEventQueue();

        expect(core.resumeCalls.length, greaterThan(before));
      });

      test('runOutgoingTransfer sends the offer, pumps and marks the message sent', () async {
        core.outgoingChunks.add(Uint8List.fromList([3]));
        await service.start();
        await pumpEventQueue();

        await service.runOutgoingTransfer(contact, fileId, offer: Uint8List.fromList([0x0E]), messageId: 12);

        expect(transport.sendCalls.where((b) => listEquals(b, [0x0E])), hasLength(1));
        expect(transport.sendFileCalls, [Uint8List.fromList([3])]);
        expect(core.markSentCalls, [12]);
        expect(core.markFailedCalls, isEmpty);
      });

      test('one lifecycle per file_id: a resume during a running send joins it and resends the offer', () async {
        core.offerToSeal = Uint8List.fromList([0x0F]);
        core.receiveProgress = waiting();
        await service.start();
        await pumpEventQueue();

        final first = service.runOutgoingTransfer(contact, fileId, messageId: 5, offer: Uint8List.fromList([0x0E]));
        final second = service.runOutgoingTransfer(contact, fileId, messageId: 5);
        expect(identical(first, second), isTrue);
        core.resumable = [send(needsOffer: true)];
        await service.resumeTransfers(contact);
        await pumpEventQueue();

        expect(transport.sendCalls.where((b) => listEquals(b, [0x0E])), hasLength(1));
        expect(transport.sendCalls.where((b) => listEquals(b, [0x0F])), hasLength(1),
            reason: 'o par pode ter perdido a oferta com a sessão anterior (decisão 8)');
        expect(core.sealOfferCalls, 1);
        core.receiveProgress = null;
        await first;
      });

      test('the offer is sealed only when the resumed send actually starts', () async {
        core.resumable = [send()];
        await service.start();
        await pumpEventQueue();

        expect(core.sealOfferCalls, 0, reason: 'oferta já respondida não é selada');
      });

      test('an abandoned receive delivers its notice to the sender', () async {
        core.resumable = [
          ResumedTransferDto(
            fileId: fileId,
            direction: ResumedDirectionDto.abandoned,
            needsOffer: false,
            sealedNotice: Uint8List.fromList([0x24]),
          ),
        ];
        core.sessionState = SessionStateKind.established;
        await service.start();
        await pumpEventQueue();

        expect(transport.sendCalls.where((b) => listEquals(b, [0x24])), hasLength(1));
        expect(core.fileFeedbackCalls, 0);
      });

      test('the pump follows a transport the router replaced instead of failing', () async {
        core.receiveProgress = waiting();
        await service.start();
        await pumpEventQueue();
        final run = service.runOutgoingTransfer(contact, fileId, messageId: 5);
        await pumpEventQueue();

        await router.closeContact(contact);
        final replacement = _FakeP2PTransport();
        transport = replacement;
        router.incomingFor(contact);
        core.outgoingChunks.add(Uint8List.fromList([4]));
        // O canal novo acorda o laço sem esperar um aviso do Rust.
        await pumpEventQueue();

        expect(replacement.sendFileCalls, [Uint8List.fromList([4])]);
        expect(core.markFailedCalls, isEmpty);
        core.receiveProgress = null;
        await run;
        expect(core.markSentCalls, contains(5));
      });

      test('the pump waits for ChunkReleased instead of polling, with a long fallback', () {
        fakeAsync((async) {
          final waitingService = MessageReceptionService(core: core, router: router);
          core.receiveProgress = waiting();
          router.incomingFor(contact);
          unawaited(waitingService.runOutgoingTransfer(contact, fileId, messageId: 5).catchError((Object _) {}));
          async.flushMicrotasks();
          final reads = core.nextChunkCalls.length;

          // Um chunk que o Rust liberou sem avisar não é visto pelo laço: não há
          // mais espera curta de 100 ms para achá-lo.
          core.outgoingChunks.add(Uint8List.fromList([7]));
          async.elapse(const Duration(seconds: 4));
          expect(core.nextChunkCalls.length, reads);
          expect(transport.sendFileCalls, isEmpty);

          // O teto de segurança reconsulta mesmo sem aviso.
          async.elapse(const Duration(seconds: 2));
          expect(transport.sendFileCalls, [Uint8List.fromList([7])]);

          core.receiveProgress = null;
          unawaited(waitingService.dispose());
          async.flushMicrotasks();
        });
      });

      test('ChunkReleased for another file does not wake the pump', () {
        fakeAsync((async) {
          final waitingService = MessageReceptionService(core: core, router: router);
          core.receiveProgress = waiting();
          router.incomingFor(contact);
          unawaited(waitingService.runOutgoingTransfer(contact, fileId, messageId: 5).catchError((Object _) {}));
          async.flushMicrotasks();
          final reads = core.nextChunkCalls.length;

          core.emitTransferEvent(TransferEventDto(
            peerDeviceId: Uint8List.fromList(contact.deviceId),
            fileId: Uint8List.fromList(List.filled(16, 0x01)),
            kind: TransferEventKind.chunkReleased,
          ));
          async.flushMicrotasks();
          expect(core.nextChunkCalls.length, reads);

          core.receiveProgress = null;
          unawaited(waitingService.dispose());
          async.flushMicrotasks();
        });
      });

      test('ChunkReleased arriving while the sender is being read is not lost', () async {
        core.receiveProgress = waiting();
        core.outgoingChunks.add(Uint8List.fromList([2]));
        // O aviso chega durante a leitura do emissor, antes de o laço esperar.
        core.onNextChunkRead = () {
          core.onNextChunkRead = null;
          core.emitTransferEvent(TransferEventDto(
            peerDeviceId: Uint8List.fromList(contact.deviceId),
            fileId: fileId,
            kind: TransferEventKind.chunkReleased,
          ));
        };
        await service.start();
        await pumpEventQueue();
        final run = service.runOutgoingTransfer(contact, fileId, messageId: 5, offer: Uint8List.fromList([1]));
        await pumpEventQueue();
        core.outgoingChunks.add(Uint8List.fromList([3]));
        core.emitTransferEvent(TransferEventDto(
          peerDeviceId: Uint8List.fromList(contact.deviceId),
          fileId: fileId,
          kind: TransferEventKind.chunkReleased,
        ));
        await pumpEventQueue();

        expect(transport.sendFileCalls, [Uint8List.fromList([2]), Uint8List.fromList([3])]);
        core.receiveProgress = null;
        core.emitTransferEvent(TransferEventDto(
          peerDeviceId: Uint8List.fromList(contact.deviceId),
          fileId: fileId,
          kind: TransferEventKind.chunkReleased,
        ));
        await run;
      });

      test('a completed send keeps pumping when the sender rewinds, then stops quietly', () {
        fakeAsync((async) {
          final idle = MessageReceptionService(
            core: core,
            router: router,
            idleLimit: const Duration(minutes: 2),
          );
          core.receiveProgress = TransferProgressDto(
            blocksDone: 2,
            totalBlocks: 2,
            bytesDone: BigInt.from(20),
            isComplete: true,
            awaitingAnswer: false,
          );
          router.incomingFor(contact);
          var done = false;
          unawaited(idle.runOutgoingTransfer(contact, fileId, messageId: 5).then((_) => done = true));
          async.flushMicrotasks();
          expect(done, isTrue, reason: 'quem chamou não espera o laço que sobra');
          expect(core.markSentCalls, [5]);

          // O receptor retomou atrás: o emissor recuou e tem o que mandar de novo.
          core.receiveProgress = waiting();
          core.outgoingChunks.add(Uint8List.fromList([9]));
          core.emitTransferEvent(TransferEventDto(
            peerDeviceId: Uint8List.fromList(contact.deviceId),
            fileId: fileId,
            kind: TransferEventKind.chunkReleased,
          ));
          async.flushMicrotasks();
          expect(transport.sendFileCalls.where((b) => listEquals(b, [9])), hasLength(1));

          async.elapse(const Duration(minutes: 3));
          expect(core.markFailedCalls, isEmpty, reason: 'depois de completar, parar não é falha');
          unawaited(idle.dispose());
          async.flushMicrotasks();
        });
      });

      test('resumes for one contact run one after the other', () async {
        await service.start();
        await pumpEventQueue();
        core.resumeCalls.clear();
        core.maxResumesInFlight = 0;
        core.resumeGate = Completer<void>();

        final first = service.resumeTransfers(contact);
        final second = service.resumeTransfers(contact);
        await pumpEventQueue();
        expect(core.resumesInFlight, 1, reason: 'a segunda espera a primeira terminar');

        core.resumeGate!.complete();
        await Future.wait([first, second]);
        expect(core.resumeCalls, hasLength(2));
        expect(core.maxResumesInFlight, 1);
      });

      test('a complete receive seen by the feedback tick is finished once', () async {
        core.pendingOffers = [
          FileOfferDto(fileId: fileId, name: 'a.bin', fileSize: BigInt.from(2)),
        ];
        core.receiveProgress = TransferProgressDto(
          blocksDone: 1,
          totalBlocks: 1,
          bytesDone: BigInt.from(2),
          isComplete: true,
          awaitingAnswer: false,
        );
        await service.start();
        await pumpEventQueue();

        await service.watchIncomingTransfer(contact, fileId);
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        expect(core.finishReceiveFileCalls, hasLength(1));
      });

      test('a finish that fails before the commit is retried by the next feedback tick', () async {
        core.finishFailuresLeft = 1;
        core.pendingOffers = [
          FileOfferDto(fileId: fileId, name: 'a.bin', fileSize: BigInt.from(2)),
        ];
        core.receiveProgress = TransferProgressDto(
          blocksDone: 1,
          totalBlocks: 1,
          bytesDone: BigInt.from(2),
          isComplete: true,
          awaitingAnswer: false,
        );
        core.ingestWireChunkHandler = (_) => IngestedChunkDto(fileId: fileId, progress: core.receiveProgress!);
        await service.start();
        await pumpEventQueue();
        final events = <MessageReceptionEvent>[];
        final sub = service.eventsFor(contact).listen(events.add);

        transport.emitIncomingFile(Uint8List.fromList([1]));
        await Future<void>.delayed(const Duration(milliseconds: 1300));

        expect(core.finishReceiveFileCalls, hasLength(2));
        expect(events.whereType<FileReceivedEvent>(), hasLength(1));
        await sub.cancel();
      });

      test('a committed file is kept when FILE_COMPLETE cannot be sealed', () async {
        core.fileCompleteToReturn = null;
        core.pendingOffers = [
          FileOfferDto(fileId: fileId, name: 'a.bin', fileSize: BigInt.from(2)),
        ];
        core.ingestWireChunkHandler = (_) => IngestedChunkDto(
              fileId: fileId,
              progress: TransferProgressDto(
                blocksDone: 1,
                totalBlocks: 1,
                bytesDone: BigInt.from(2),
                isComplete: true,
                awaitingAnswer: false,
              ),
            );
        await service.start();
        await pumpEventQueue();
        final events = <MessageReceptionEvent>[];
        final sub = service.eventsFor(contact).listen(events.add);

        transport.emitIncomingFile(Uint8List.fromList([1]));
        await pumpEventQueue();

        final saved = service.getReceivedFilePath(fileId);
        expect(saved, isNotNull);
        expect(File(saved!).existsSync(), isTrue);
        expect(events.whereType<FileReceivedEvent>(), hasLength(1));
        expect(transport.sendCalls.where((b) => listEquals(b, [0xAA, 0xBB])), isEmpty);
        await sub.cancel();
      });

      test('an accepted send with no progress stops after the idle limit', () {
        fakeAsync((async) {
          final idle = MessageReceptionService(
            core: core,
            router: router,
            idleLimit: const Duration(minutes: 2),
          );
          core.receiveProgress = waiting();
          router.incomingFor(contact);
          Object? error;
          idle.runOutgoingTransfer(contact, fileId, messageId: 5).catchError((Object e) => error = e);

          async.elapse(const Duration(minutes: 1));
          expect(error, isNull);
          async.elapse(const Duration(minutes: 2));

          expect(error, isA<TransferStalledException>());
          expect(core.markFailedCalls, [5]);
          unawaited(idle.dispose());
          async.flushMicrotasks();
        });
      });

      test('a send still waiting for the offer to be answered is not stopped', () {
        fakeAsync((async) {
          final idle = MessageReceptionService(
            core: core,
            router: router,
            idleLimit: const Duration(minutes: 2),
          );
          core.receiveProgress = waiting(awaitingAnswer: true);
          router.incomingFor(contact);
          Object? error;
          idle.runOutgoingTransfer(contact, fileId, messageId: 5).catchError((Object e) => error = e);

          async.elapse(const Duration(minutes: 10));
          expect(error, isNull);
          expect(core.markFailedCalls, isEmpty);

          core.receiveProgress = null;
          async.elapse(const Duration(seconds: 1));
          unawaited(idle.dispose());
          async.flushMicrotasks();
        });
      });
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

    test('republishes Rust message events as MessageChangedEvent with only identifiers', () async {
      await service.start();
      final events = <MessageChangedEvent>[];
      final sub = service.events.where((e) => e is MessageChangedEvent).cast<MessageChangedEvent>().listen(events.add);

      core.emitMessageEvent(42, MessageEventKind.keyExpired, peer: contact.deviceId);
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.contactId, contact);
      expect(events.single.messageId, 42);
      expect(events.single.kind, MessageEventKind.keyExpired);
      await sub.cancel();
    });

    test('ChunkReleased is not republished as an offer event', () async {
      await service.start();
      final events = <MessageReceptionEvent>[];
      final sub = service.events.listen(events.add);

      core.emitTransferEvent(TransferEventDto(
        peerDeviceId: Uint8List.fromList(contact.deviceId),
        fileId: Uint8List.fromList(List.filled(16, 4)),
        kind: TransferEventKind.chunkReleased,
      ));
      await pumpEventQueue();

      expect(events.whereType<OffersChangedEvent>(), isEmpty);
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
              isComplete: true, awaitingAnswer: false
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
              isComplete: true, awaitingAnswer: false
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
            isComplete: isComplete, awaitingAnswer: false
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

      test('stops after the idle limit without progress, and a new chunk restarts it', () {
        fakeAsync((async) {
          final idle = MessageReceptionService(
            core: core,
            router: router,
            idleLimit: const Duration(minutes: 2),
          );
          core.receiveProgress = progress(blocksDone: 1);
          router.incomingFor(contact);
          unawaited(idle.watchIncomingTransfer(contact, fileId));
          async.flushMicrotasks();

          async.elapse(const Duration(minutes: 3));
          final sent = core.fileFeedbackCalls;
          expect(async.periodicTimerCount, 0, reason: 'o emissor sumiu: o feedback para');
          async.elapse(const Duration(minutes: 1));
          expect(core.fileFeedbackCalls, sent);

          unawaited(idle.watchIncomingTransfer(contact, fileId));
          async.flushMicrotasks();
          expect(core.fileFeedbackCalls, sent + 1);
          core.receiveProgress = null;
          async.elapse(const Duration(milliseconds: 500));
          unawaited(idle.dispose());
          async.flushMicrotasks();
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
            isComplete: complete, awaitingAnswer: false
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
        // O serviço só cai depois do commit, que passa por E/S de arquivo de
        // verdade: espera por ele em vez de contar voltas da fila de eventos.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!serviceCalls.contains('stop') && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
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
