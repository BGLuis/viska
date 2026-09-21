import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:viska/src/features/chat/chat_controller.dart';
import 'package:viska/src/features/voice/voice_io.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

/// Substitui `PathProviderPlatform.instance` por um diretório temporário de
/// verdade (do sistema de arquivos real, não um canal de plataforma) — os
/// caminhos que `ChatController` monta para gravação/recebimento de nota de
/// voz continuam sendo arquivos reais, só que num diretório efêmero de
/// teste em vez de um específico do aparelho.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.tempDir);

  final Directory tempDir;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;
}

/// Dublê de `VoiceRecorder` — `stop()` devolve sempre o mesmo caminho
/// configurável, sem tocar nenhum canal de plataforma de verdade.
class _FakeVoiceRecorder implements VoiceRecorder {
  String? pathToReturnOnStop;
  var startCalls = 0;
  var throwOnStart = false;

  @override
  Future<void> start(String path) async {
    startCalls++;
    if (throwOnStart) throw StateError('codec não suportado');
  }

  @override
  Future<String?> stop() async => pathToReturnOnStop;

  @override
  Future<void> dispose() async {}
}

class _FakeVoicePlayer implements VoicePlayer {
  final playedBytes = <Uint8List>[];
  var stopCalls = 0;

  @override
  Future<void> playBytes(Uint8List wavBytes) async {
    playedBytes.add(wavBytes);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}
}

/// Substitui `PermissionHandlerPlatform.instance` — evita depender do canal
/// de plataforma real do `permission_handler` em `flutter test`. Concedida
/// por padrão; `denyMicrophone` simula o usuário recusando.
class _FakePermissionHandlerPlatform extends PermissionHandlerPlatform {
  var denyMicrophone = false;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    return {
      for (final permission in permissions)
        permission: denyMicrophone && permission == Permission.microphone
            ? PermissionStatus.denied
            : PermissionStatus.granted,
    };
  }
}

/// Só implementa o que `ChatController` de fato chama — o resto arremessa
/// `UnimplementedError` de propósito (ver o mesmo padrão em
/// `webrtc_p2p_transport_test.dart`).
class _FakeCore implements Core {
  SessionStateKind sessionState = SessionStateKind.handshaking;
  Uint8List? outgoingHandshake;
  var needsRehandshake = false;

  List<MessageDto> messagesToReturn = [];
  final sealOutgoingTextCalls = <String>[];
  final markSentCalls = <int>[];
  final feedHandshakeCalls = <Uint8List>[];
  final decryptIncomingCalls = <Uint8List>[];

  Uint8List? feedHandshakeResponse;
  var establishOnFeedHandshake = false;
  IncomingMessageDto? Function(Uint8List)? decryptIncomingHandler;
  List<SealedMessageDto> pendingToFlush = [];
  SealedMessageDto Function(String body)? sealOutgoingTextHandler;
  var nextMessageId = 1;

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: sessionState,
        needsRehandshake: needsRehandshake,
        outgoingHandshake: outgoingHandshake,
      );

  @override
  Future<SessionStatusDto?> sessionStatus({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: sessionState,
        needsRehandshake: needsRehandshake,
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
  Future<SealedMessageDto> sealOutgoingText({
    required List<int> peerDeviceId,
    required String body,
  }) async {
    sealOutgoingTextCalls.add(body);
    final id = nextMessageId++;
    if (sealOutgoingTextHandler != null) {
      return sealOutgoingTextHandler!(body);
    }
    return SealedMessageDto(
      messageId: id,
      bytes: sessionState == SessionStateKind.established
          ? Uint8List.fromList([1, 2, 3])
          : null,
    );
  }

  @override
  Future<IncomingMessageDto?> decryptIncoming({
    required List<int> peerDeviceId,
    required List<int> envelope,
  }) async {
    final bytes = Uint8List.fromList(envelope);
    decryptIncomingCalls.add(bytes);
    return decryptIncomingHandler != null ? decryptIncomingHandler!(bytes) : null;
  }

  @override
  Future<List<SealedMessageDto>> flushPending({required List<int> peerDeviceId}) async {
    final result = pendingToFlush;
    pendingToFlush = [];
    return result;
  }

  @override
  Future<void> markMessageSent({required PlatformInt64 messageId}) async {
    markSentCalls.add(messageId);
  }

  @override
  Future<List<MessageDto>> listMessages({required List<int> peerDeviceId}) async =>
      messagesToReturn;

  @override
  Future<Uint8List?> openSignalingPayload({
    required List<int> peerDeviceId,
    required List<int> sealed,
  }) =>
      throw UnimplementedError();

  @override
  Future<DiscoveryBeaconsDto> discoveryBeacons({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<List<ContactDto>> listContacts() => throw UnimplementedError();

  @override
  Future<ContactDto?> matchDiscoveredBeacon({required List<int> beacon}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> myDeviceId() => throw UnimplementedError();

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
  Future<Uint8List> sealSignalingPayload({
    required List<int> peerDeviceId,
    required List<int> payloadBytes,
  }) =>
      throw UnimplementedError();

  @override
  Future<SignalingTopicsDto> signalingTopics({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  // Fase 4 — transferência de arquivo genérico: `ChatController` não chama
  // nenhum destes ainda; stubs só para o fake continuar implementando
  // `Core` por inteiro.
  @override
  Future<void> cancelTransfer({required List<int> fileId}) => throw UnimplementedError();

  @override
  Future<Uint8List> finishReceiveFile({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<FileOfferDto>> pendingFileOffers({required List<int> peerDeviceId}) =>
      throw UnimplementedError();

  @override
  Future<SendFileStartedDto> startSendFile({
    required List<int> peerDeviceId,
    required String filePath,
    required bool useLan,
  }) =>
      throw UnimplementedError();

  // Fase 5 — nota de voz: configuráveis por teste (ver campos acima de
  // cada implementação), com um padrão razoável quando o teste não se
  // importa com o valor exato.
  final sanitizeAndStageAudioCalls = <String>[];
  final startSendAudioCalls = <String>[];
  SendAudioStartedDto Function(String audioPath)? startSendAudioHandler;
  final ingestIncomingWireBytesCalls = <Uint8List>[];
  IngestedChunkDto? Function(Uint8List)? ingestIncomingWireBytesHandler;
  final nextOutgoingWireChunkCalls = <Uint8List>[];
  Uint8List? Function(Uint8List fileId)? nextOutgoingWireChunkHandler;
  TransferProgressDto? Function(Uint8List fileId)? transferProgressHandler;
  Uint8List Function(Uint8List fileId, String destinationPath)? finishReceiveAudioHandler;
  Uint8List Function(Uint8List internalBytes)? decodeAudioToWavHandler;
  final pendingAudioOffersToReturn = <FileOfferDto>[];

  @override
  Future<void> sanitizeAndStageAudio({
    required String sourcePath,
    required String destinationPath,
  }) async {
    sanitizeAndStageAudioCalls.add(sourcePath);
    // O controlador lê `destinationPath` de volta (para cachear o WAV antes
    // de mandar) — precisa existir de verdade, mesmo num dublê.
    await File(destinationPath).writeAsBytes([9]);
  }

  @override
  Future<SendAudioStartedDto> startSendAudio({
    required List<int> peerDeviceId,
    required String audioPath,
    required bool useLan,
  }) async {
    startSendAudioCalls.add(audioPath);
    if (startSendAudioHandler != null) return startSendAudioHandler!(audioPath);
    return SendAudioStartedDto(
      fileId: Uint8List.fromList(List.filled(16, 1)),
      sealedMetadata: Uint8List.fromList([2, 2, 2]),
      messageId: nextMessageId++,
    );
  }

  @override
  Future<IngestedChunkDto?> ingestIncomingWireBytes({required List<int> wireBytes}) async {
    final bytes = Uint8List.fromList(wireBytes);
    ingestIncomingWireBytesCalls.add(bytes);
    return ingestIncomingWireBytesHandler?.call(bytes);
  }

  @override
  Future<Uint8List?> nextOutgoingWireChunk({required List<int> fileId}) async {
    final bytes = Uint8List.fromList(fileId);
    nextOutgoingWireChunkCalls.add(bytes);
    return nextOutgoingWireChunkHandler?.call(bytes);
  }

  @override
  Future<TransferProgressDto?> transferProgress({required List<int> fileId}) async =>
      transferProgressHandler?.call(Uint8List.fromList(fileId));

  @override
  Future<Uint8List> finishReceiveAudio({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) async {
    // O controlador lê `destinationPath` de volta (para decodificar o WAV)
    // — precisa existir de verdade, mesmo num dublê.
    await File(destinationPath).writeAsBytes([7]);
    return finishReceiveAudioHandler?.call(Uint8List.fromList(fileId), destinationPath) ??
        Uint8List.fromList([3, 3, 3]);
  }

  @override
  Future<Uint8List> decodeAudioToWav({required List<int> internalBytes}) async =>
      decodeAudioToWavHandler?.call(Uint8List.fromList(internalBytes)) ??
      Uint8List.fromList([4, 4, 4]);

  @override
  Future<List<FileOfferDto>> pendingAudioOffers({required List<int> peerDeviceId}) async =>
      pendingAudioOffersToReturn;

  @override
  Future<bool> isLocked() async => false;

  @override
  Future<void> lock() async {}

  @override
  Future<void> unlock() async {}

  @override
  Future<void> emergencyErase() async {}

  @override
  Future<void> setEphemeralTtl({
    required List<int> contactDeviceId,
    required PlatformInt64 ttlSecs,
  }) async {}

  @override
  Future<PlatformInt64> getEphemeralTtl({required List<int> contactDeviceId}) async => 0;

  @override
  Future<void> markMessageRead({required PlatformInt64 messageId}) async {}

  @override
  Future<int> sweepExpiredMessages() async => 0;
}

class _FakeP2PTransport implements P2PTransport {
  final sendCalls = <Uint8List>[];
  final sendFileCalls = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Future<void> connect() async {}

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
  Future<void> close() async {}

  void emitIncoming(Uint8List bytes) => _incoming.add(bytes);
  void emitIncomingFile(Uint8List bytes) => _incomingFile.add(bytes);
  void emitConnectionEvent(TransportConnectionEvent event) => _connectionEvents.add(event);
}

void main() {
  late ContactId contact;
  late _FakeCore core;
  late _FakeP2PTransport transport;
  late P2PTransportRouter router;
  late ChatController controller;
  late _FakeVoiceRecorder recorder;
  late _FakeVoicePlayer player;
  late _FakePermissionHandlerPlatform permissionPlatform;

  ChatController makeController() => ChatController(
        core: core,
        router: router,
        contactId: contact,
        recorder: recorder,
        player: player,
      );

  late Directory tempDir;

  setUp(() {
    contact = ContactId(List.generate(16, (i) => i));
    core = _FakeCore();
    transport = _FakeP2PTransport();
    router = P2PTransportRouter(
      core: core,
      transportFactory: (_, _) => transport,
    );
    recorder = _FakeVoiceRecorder();
    player = _FakeVoicePlayer();
    permissionPlatform = _FakePermissionHandlerPlatform();
    PermissionHandlerPlatform.instance = permissionPlatform;
    tempDir = Directory.systemTemp.createTempSync('viska-chat-controller-test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('initialize loads existing history', () async {
    core.messagesToReturn = [
      const MessageDto(
        id: 1,
        direction: MessageDirectionDto.incoming,
        kind: MessageKindDto.text,
        body: 'oi',
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 1000,
        isEphemeral: false,
      ),
    ];
    controller = makeController();

    await controller.initialize();

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.body, 'oi');
  });

  test('as initiator: initialize publishes pending INIT', () async {
    core.outgoingHandshake = Uint8List.fromList([9, 9, 9]);
    core.sessionState = SessionStateKind.handshaking;
    controller = makeController();

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(transport.sendCalls, [Uint8List.fromList([9, 9, 9])]);
    expect(controller.isEstablished, isFalse);
  });

  test('as responder: received INIT generates published RESP and establishes session', () async {
    core.outgoingHandshake = null; // respondedor
    core.feedHandshakeResponse = Uint8List.fromList([7, 7]);
    core.establishOnFeedHandshake = true;
    controller = makeController();
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1, 2, 3])); // "INIT" do par
    await Future<void>.delayed(Duration.zero);

    expect(core.feedHandshakeCalls, [Uint8List.fromList([1, 2, 3])]);
    expect(transport.sendCalls, [Uint8List.fromList([7, 7])]);
    expect(controller.isEstablished, isTrue);
  });

  test('established session flushes pending messages (flushPending)', () async {
    core.outgoingHandshake = null;
    core.feedHandshakeResponse = null;
    core.establishOnFeedHandshake = true;
    core.pendingToFlush = [
      SealedMessageDto(messageId: 42, bytes: Uint8List.fromList([5, 5, 5])),
    ];
    controller = makeController();
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1])); // conclui o handshake
    await Future<void>.delayed(Duration.zero);

    expect(transport.sendCalls, [Uint8List.fromList([5, 5, 5])]);
    expect(core.markSentCalls, [42]);
  });

  test('sendText with established session sends immediately and marks as sent', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();
    await controller.initialize();

    await controller.sendText('oi, bob');

    expect(core.sealOutgoingTextCalls, ['oi, bob']);
    expect(transport.sendCalls, hasLength(1));
    expect(core.markSentCalls, hasLength(1));
  });

  test('sendText with session not yet established only persists (does not send)', () async {
    core.sessionState = SessionStateKind.handshaking;
    controller = makeController();
    await controller.initialize();

    await controller.sendText('mensagem adiantada');

    expect(core.sealOutgoingTextCalls, ['mensagem adiantada']);
    expect(transport.sendCalls, isEmpty);
    expect(core.markSentCalls, isEmpty);
  });

  test('sendText ignores empty text', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();
    await controller.initialize();

    await controller.sendText('');

    expect(core.sealOutgoingTextCalls, isEmpty);
  });

  test('received message with established session decrypts and updates history', () async {
    core.sessionState = SessionStateKind.established;
    core.decryptIncomingHandler = (bytes) => const IncomingMessageDto(
          messageId: 5,
          body: 'recebida',
          isTyping: false,
          receivedAtUnixSecs: 123,
        );
    core.messagesToReturn = [
      const MessageDto(
        id: 5,
        direction: MessageDirectionDto.incoming,
        kind: MessageKindDto.text,
        body: 'recebida',
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 123,
        isEphemeral: false,
      ),
    ];
    controller = makeController();
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1, 1, 1]));
    await Future<void>.delayed(Duration.zero);

    expect(core.decryptIncomingCalls, [Uint8List.fromList([1, 1, 1])]);
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.body, 'recebida');
  });

  test('AEAD failure (null) does not crash controller', () async {
    core.sessionState = SessionStateKind.established;
    core.decryptIncomingHandler = (_) => null;
    controller = makeController();
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([9, 9]));
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages, isEmpty);
  });

  test('typing indicator (isTyping) is not added to history', () async {
    core.sessionState = SessionStateKind.established;
    core.decryptIncomingHandler = (_) => const IncomingMessageDto(
          messageId: null,
          body: '',
          isTyping: true,
          receivedAtUnixSecs: 0,
        );
    controller = makeController();
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages, isEmpty);
  });

  test('failed connection event sets connectionError', () async {
    controller = makeController();
    await controller.initialize();

    transport.emitConnectionEvent(
      const TransportConnectionEvent(TransportConnectionState.failed, reason: 'sem rota'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.connectionError, 'sem rota');
  });

  test('dispose cancels subscriptions - subsequent events no longer affect state', () async {
    controller = makeController();
    await controller.initialize();
    controller.dispose();

    transport.emitConnectionEvent(
      const TransportConnectionEvent(TransportConnectionState.failed, reason: 'tarde demais'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.connectionError, isNull);
  });

  group('voice note (Phase 5)', () {
    test('startRecording requests permission and fails with clear message if denied', () async {
      permissionPlatform.denyMicrophone = true;
      controller = makeController();
      await controller.initialize();

      await controller.startRecording();

      expect(controller.isRecording, isFalse);
      expect(controller.voiceError, isNotNull);
      expect(recorder.startCalls, 0);
    });

    test('startRecording fails loudly if recorder does not support Opus, without falling back to another codec', () async {
      recorder.throwOnStart = true;
      controller = makeController();
      await controller.initialize();

      await controller.startRecording();

      expect(controller.isRecording, isFalse);
      expect(controller.voiceError, contains('Opus'));
    });

    test('startRecording when granted starts recording', () async {
      controller = makeController();
      await controller.initialize();

      await controller.startRecording();

      expect(controller.isRecording, isTrue);
      expect(recorder.startCalls, 1);
      expect(controller.voiceError, isNull);
    });

    test('stopRecordingAndSend with no recording in progress is a no-op', () async {
      controller = makeController();
      await controller.initialize();

      await controller.stopRecordingAndSend();

      expect(core.startSendAudioCalls, isEmpty);
    });

    test(
      'stopRecordingAndSend sanitizes, caches WAV, publishes FILE_METADATA, pumps chunks through file channel and marks message as sent',
      () async {
        recorder.pathToReturnOnStop = '${tempDir.path}/gravado.ogg';

        final fileId = Uint8List.fromList(List.filled(16, 7));
        core.startSendAudioHandler = (_) => SendAudioStartedDto(
              fileId: fileId,
              sealedMetadata: Uint8List.fromList([1, 1, 1]),
              messageId: 99,
            );
        var chunkCalls = 0;
        core.nextOutgoingWireChunkHandler = (_) {
          chunkCalls++;
          return chunkCalls <= 2 ? Uint8List.fromList([chunkCalls]) : null;
        };
        core.transferProgressHandler = (_) => TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(100),
              isComplete: true,
            );
        core.decodeAudioToWavHandler = (_) => Uint8List.fromList([6, 6, 6]);

        controller = makeController();
        await controller.initialize();
        await controller.startRecording();
        await controller.stopRecordingAndSend();

        expect(core.sanitizeAndStageAudioCalls, [recorder.pathToReturnOnStop]);
        expect(core.startSendAudioCalls, hasLength(1));
        expect(transport.sendCalls, [Uint8List.fromList([1, 1, 1])], reason: 'FILE_METADATA vai pelo canal control');
        expect(transport.sendFileCalls, [
          Uint8List.fromList([1]),
          Uint8List.fromList([2]),
        ], reason: 'pedaços vão pelo canal file, na ordem que nextOutgoingWireChunk devolveu');
        expect(core.markSentCalls, [99]);
        expect(controller.isSendingVoice, isFalse);
        expect(controller.voiceError, isNull);

        final sent = MessageDto(
          id: 99,
          direction: MessageDirectionDto.outgoing,
          kind: MessageKindDto.voiceNote,
          body: '',
          audioFileId: fileId,
          deliveryState: DeliveryStateDto.sent,
          createdAtUnixSecs: 0,
          isEphemeral: false,
        );
        expect(controller.isVoiceNoteReady(sent), isTrue, reason: 'cacheado antes de mandar, para poder reproduzir a própria nota enviada');
      },
    );

    test('error starting send (e.g. no session) becomes voiceError, not exception', () async {
      recorder.pathToReturnOnStop = '${tempDir.path}/gravado.ogg';
      core.startSendAudioHandler = (_) => throw StateError('sem sessão ativa');

      controller = makeController();
      await controller.initialize();
      await controller.startRecording();
      await controller.stopRecordingAndSend();

      expect(controller.voiceError, isNotNull);
      expect(controller.isSendingVoice, isFalse);
    });

    test(
      'complete packet on file channel confirms FILE_COMPLETE and decodes note to WAV',
      () async {
        final fileId = Uint8List.fromList(List.filled(16, 3));
        core.messagesToReturn = [
          MessageDto(
            id: 10,
            direction: MessageDirectionDto.incoming,
            kind: MessageKindDto.voiceNote,
            body: '',
            audioFileId: fileId,
            deliveryState: DeliveryStateDto.delivered,
            createdAtUnixSecs: 500,
            isEphemeral: false,
          ),
        ];
        core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
              fileId: fileId,
              progress: TransferProgressDto(
                blocksDone: 1,
                totalBlocks: 1,
                bytesDone: BigInt.from(10),
                isComplete: true,
              ),
            );
        core.finishReceiveAudioHandler = (_, _) => Uint8List.fromList([5, 5, 5]);
        core.decodeAudioToWavHandler = (_) => Uint8List.fromList([6, 6, 6]);

        controller = makeController();
        await controller.initialize();
        final message = controller.messages.single;
        expect(controller.isVoiceNoteReady(message), isFalse, reason: 'ainda não chegou nenhum AUDIO_CHUNK');

        transport.emitIncomingFile(Uint8List.fromList([9, 9]));
        // A conclusão encadeia vários `await` de verdade (I/O de arquivo
        // real no diretório temporário de teste) — aguarda até o processamento
        // assíncrono refletir o WAV decodificado em memória.
        for (var i = 0; i < 50 && !controller.isVoiceNoteReady(message); i++) {
          await pumpEventQueue(times: 10);
        }

        expect(core.ingestIncomingWireBytesCalls, [Uint8List.fromList([9, 9])]);
        expect(transport.sendCalls, [Uint8List.fromList([5, 5, 5])], reason: 'FILE_COMPLETE de volta ao emissor, pelo canal control');
        expect(controller.isVoiceNoteReady(message), isTrue);
      },
    );

    test('incomplete packet on file channel neither confirms nor decodes anything yet', () async {
      final fileId = Uint8List.fromList(List.filled(16, 2));
      core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 0,
              totalBlocks: 4,
              bytesDone: BigInt.from(10),
              isComplete: false,
            ),
          );
      controller = makeController();
      await controller.initialize();

      transport.emitIncomingFile(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);

      expect(transport.sendCalls, isEmpty);
    });

    test('packet with unknown file_id (ingestIncomingWireBytes returns null) is ignored', () async {
      core.ingestIncomingWireBytesHandler = (_) => null;
      controller = makeController();
      await controller.initialize();

      transport.emitIncomingFile(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);

      expect(transport.sendCalls, isEmpty);
    });

    test('play plays cached WAV and stopVoicePlayback stops', () async {
      final fileId = Uint8List.fromList(List.filled(16, 4));
      core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(1),
              isComplete: true,
            ),
          );
      core.decodeAudioToWavHandler = (_) => Uint8List.fromList([8, 8, 8]);
      controller = makeController();
      await controller.initialize();

      final message = MessageDto(
        id: 1,
        direction: MessageDirectionDto.incoming,
        kind: MessageKindDto.voiceNote,
        body: '',
        audioFileId: fileId,
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 0,
        isEphemeral: false,
      );

      transport.emitIncomingFile(Uint8List.fromList([1]));
      for (var i = 0; i < 50 && !controller.isVoiceNoteReady(message); i++) {
        await pumpEventQueue(times: 10);
      }

      await controller.play(message);
      expect(player.playedBytes, [Uint8List.fromList([8, 8, 8])]);
      expect(controller.playingMessageId, 1);

      await controller.stopVoicePlayback();
      expect(player.stopCalls, 1);
      expect(controller.playingMessageId, isNull);
    });
  });
}
