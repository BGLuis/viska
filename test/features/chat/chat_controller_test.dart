import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:viska/src/features/chat/chat_controller.dart';
import 'package:viska/src/features/voice/voice_io.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/rust/lib.dart';
import 'package:viska/src/transport/lan/lan_transport.dart';
import 'package:viska/src/transport/message_reception_service.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

import '../../support/fake_session_events.dart';

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
class _FakeCore with FakeSessionEvents implements Core {
  _FakeCore() {
    peerDeviceId = List.generate(16, (i) => i);
    sessionState = SessionStateKind.handshaking;
  }

  Uint8List? outgoingHandshake;
  final resetSessionCalls = <List<int>>[];
  SessionStatusDto? resetSessionResult;
  Object? resetSessionError;

  /// Estado que `sessionStatus` devolve sem que o stream o tenha publicado —
  /// a janela entre o Rust mudar a sessão e o evento chegar ao Dart.
  SessionStateKind? silentStatusOverride;

  List<MessageDto> messagesToReturn = [];
  final sealOutgoingTextCalls = <String>[];
  final markSentCalls = <int>[];
  final requeueCalls = <int>[];
  final feedHandshakeCalls = <Uint8List>[];
  final decryptIncomingCalls = <Uint8List>[];

  Uint8List? feedHandshakeResponse;
  var establishOnFeedHandshake = false;
  IncomingMessageDto? Function(Uint8List)? decryptIncomingHandler;
  List<SealedMessageDto> pendingToFlush = [];
  SealedMessageDto Function(String body)? sealOutgoingTextHandler;
  var nextMessageId = 1;

  @override
  Future<SessionStatusDto> resetSession({required List<int> peerDeviceId}) async {
    resetSessionCalls.add(peerDeviceId);
    if (resetSessionError != null) throw resetSessionError!;
    return resetSessionResult ??
        SessionStatusDto(
          state: SessionStateKind.handshaking,
          needsRehandshake: false,
          outgoingHandshake: outgoingHandshake,
        );
  }

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
        state: silentStatusOverride ?? sessionState,
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
  Future<void> requeueMessage({required PlatformInt64 messageId}) async {
    requeueCalls.add(messageId);
  }

  @override
  Future<void> markMessageSent({required PlatformInt64 messageId}) async {
    markSentCalls.add(messageId);
    if (failMarkSent) throw StateError('banco indisponível');
  }

  bool failMarkSent = false;
  bool failMarkFailed = false;

  final markFailedCalls = <int>[];

  @override
  Future<void> markMessageFailed({required PlatformInt64 messageId}) async {
    markFailedCalls.add(messageId);
    if (failMarkFailed) throw StateError('banco indisponível');
    messagesToReturn = [
      for (final m in messagesToReturn)
        if (m.id == messageId)
          MessageDto(
            id: m.id,
            direction: m.direction,
            kind: m.kind,
            body: m.body,
            deliveryState: DeliveryStateDto.failed,
            createdAtUnixSecs: m.createdAtUnixSecs,
            isEphemeral: m.isEphemeral,
            viewOnce: m.viewOnce,
            reactions: m.reactions,
          )
        else
          m,
    ];
  }

  final List<PlatformInt64> markDeliveredCalls = [];

  @override
  Future<void> markMessageDelivered({required PlatformInt64 messageId}) async {
    markDeliveredCalls.add(messageId);
  }

  @override
  Future<SealedMessageDto> sealOutgoingReceipt({
    required List<int> peerDeviceId,
    required String targetId,
  }) async {
    return SealedMessageDto(
      messageId: 0,
      bytes: Uint8List.fromList([0x11, 1, 2, 3]),
    );
  }

  @override
  Future<List<MessageDto>> listMessages({required List<int> peerDeviceId}) async =>
      messagesToReturn;

  @override
  Future<List<MessageDto>> listMessagesPaginated({
    required List<int> peerDeviceId,
    PlatformInt64? sinceId,
    BigInt? limit,
  }) async {
    var res = messagesToReturn;
    if (sinceId != null) {
      res = res.where((m) => m.id > sinceId).toList();
    }
    if (limit != null) {
      res = res.take(limit.toInt()).toList();
    }
    return res;
  }

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

  // Fase 4 — transferência de arquivo genérico: configuráveis por teste no
  // mesmo padrão dos stubs de áudio (Fase 5) acima.
  FutureOr<SendFileStartedDto> Function(String filePath)? startSendFileHandler;
  final startSendFileCalls = <String>[];
  final startSendFileUseLan = <bool>[];
  final finishReceiveFileCalls = <String>[];
  Uint8List Function(Uint8List fileId, String destinationPath)? finishReceiveFileHandler;
  List<FileOfferDto> pendingFileOffersToReturn = [];

  @override
  Future<void> cancelTransfer({required List<int> fileId}) async {}

  Uint8List? fileFeedbackResponse;
  final fileFeedbackCalls = <Uint8List>[];

  @override
  Future<Uint8List> fileFeedback({
    required List<int> peerDeviceId,
    required List<int> fileId,
  }) async {
    fileFeedbackCalls.add(Uint8List.fromList(fileId));
    if (fileFeedbackResponse != null) {
      return fileFeedbackResponse!;
    }
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> finishReceiveFile({
    required List<int> peerDeviceId,
    required List<int> fileId,
    required String destinationPath,
  }) async {
    finishReceiveFileCalls.add(destinationPath);
    // Cria o arquivo de destino para que o controller possa verificar que
    // ele existe — mesmo padrão de finishReceiveAudio no fake acima.
    await File(destinationPath).writeAsBytes([42]);
    return finishReceiveFileHandler?.call(Uint8List.fromList(fileId), destinationPath) ??
        Uint8List.fromList([5, 5, 5]);
  }

  @override
  Future<List<FileOfferDto>> pendingFileOffers({required List<int> peerDeviceId}) async =>
      pendingFileOffersToReturn;

  @override
  Future<SendFileStartedDto> startSendFile({
    required List<int> peerDeviceId,
    required String filePath,
    required bool useLan,
  }) async {
    startSendFileCalls.add(filePath);
    startSendFileUseLan.add(useLan);
    if (startSendFileHandler != null) return await startSendFileHandler!(filePath);
    return SendFileStartedDto(
      fileId: Uint8List.fromList(List.filled(16, 5)),
      sealedMetadata: Uint8List.fromList([8, 8, 8]),
      messageId: nextMessageId++,
    );
  }

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
  FutureOr<Uint8List> Function(Uint8List internalBytes)? decodeAudioToWavHandler;
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
      await decodeAudioToWavHandler?.call(Uint8List.fromList(internalBytes)) ??
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
  Future<List<Uint8List>> listActiveFileTransferIds() async => [];

  @override
  Future<int> sweepExpiredMessages() async => 0;

  @override
  Future<void> addReaction({
    required PlatformInt64 targetMsgId,
    required U8Array16 contactDeviceId,
    required String emoji,
  }) async {}

  @override
  Future<bool> addReactionByGlobalId({
    required U8Array16 contactDeviceId,
    required String targetGlobalId,
    required String emoji,
  }) async => true;

  @override
  Future<void> configureDuressPin({
    required String duressPin,
    required int actionMode,
  }) async {}

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

  bool contactVerified = false;
  bool keyChanged = false;

  @override
  Future<bool> isContactVerified({required List<int> contactDeviceId}) async =>
      contactVerified;

  @override
  Future<void> verifyContact({
    required List<int> contactDeviceId,
    required bool verified,
  }) async {
    contactVerified = verified;
  }

  @override
  Future<bool> isKeyChanged({required List<int> contactDeviceId}) async =>
      keyChanged;

  List<FileOfferDto> unconfirmedFileOffersToReturn = [];
  FfiError? unconfirmedFileOffersError;
  final acceptFileOfferCalls = <Uint8List>[];
  final rejectFileOfferCalls = <Uint8List>[];
  FfiError? offerActionError;

  /// O que `rejectFileOffer` devolve: o `FILE_REJECT` selado, ou `null` sem sessão.
  Uint8List? sealedRejectToReturn;

  @override
  Future<void> acceptFileOffer({required List<int> fileId}) async {
    acceptFileOfferCalls.add(Uint8List.fromList(fileId));
    if (offerActionError != null) throw offerActionError!;
  }

  @override
  Future<Uint8List?> rejectFileOffer({required List<int> fileId}) async {
    rejectFileOfferCalls.add(Uint8List.fromList(fileId));
    if (offerActionError != null) throw offerActionError!;
    return sealedRejectToReturn;
  }

  @override
  Future<List<FileOfferDto>> unconfirmedFileOffers({required List<int> peerDeviceId}) async {
    if (unconfirmedFileOffersError != null) throw unconfirmedFileOffersError!;
    return unconfirmedFileOffersToReturn;
  }

  @override
  Future<BigInt> autoAcceptFileSizeLimit() async => BigInt.from(100 * 1024 * 1024);

  @override
  Future<void> setAutoAcceptFileSizeLimit({required BigInt limitBytes}) async {}

  @override
  Future<Uint8List?> buildControlSuites({required List<int> peerDeviceId}) async => null;

  @override
  Future<ContactDto> repairFromQr({required List<int> payload}) => throw UnimplementedError();
}

class _FakeP2PTransport implements P2PTransport {
  final sendCalls = <Uint8List>[];
  final sendFileCalls = <Uint8List>[];
  Object? sendError;

  /// Falha só os envelopes que o predicado aceita — o handshake também passa
  /// por `send` e não deve ser derrubado nos testes de mensagem.
  bool Function(Uint8List)? sendErrorWhen;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  /// Segura `connect()` para simular um transporte que ainda não voltou.
  Completer<void>? connectGate;

  @override
  Future<void> connect() async => connectGate?.future;

  @override
  Future<void> send(Uint8List envelope) async {
    final error = sendError;
    if (error != null && (sendErrorWhen?.call(envelope) ?? true)) throw error;
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
  Future<void> close() async {}

  void emitIncoming(Uint8List bytes) => _incoming.add(bytes);
  void emitIncomingFile(Uint8List bytes) => _incomingFile.add(bytes);
  void emitConnectionEvent(TransportConnectionEvent event) => _connectionEvents.add(event);
}

/// `LanTransport` real abre sockets e mDNS; o controller só faz `is LanTransport`,
/// então basta um fake que satisfaça o tipo.
class _FakeLanTransport extends _FakeP2PTransport implements LanTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  ChatController makeController({Duration connectTimeout = const Duration(seconds: 30)}) =>
      ChatController(
        core: core,
        router: router,
        contactId: contact,
        recorder: recorder,
        player: player,
        connectTimeout: connectTimeout,
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
      MessageDto(
        id: 1,
        direction: MessageDirectionDto.incoming,
        kind: MessageKindDto.text,
        body: 'oi',
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 1000,
        isEphemeral: false,
        viewOnce: false,
        reactions: const [],
      ),
    ];
    controller = makeController();

    await controller.initialize();

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.body, 'oi');
  });

  test('initialize reads established session', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();

    await controller.initialize();

    expect(controller.isEstablished, isTrue, reason: 'sem SessionEstablishedEvent: o evento já passou');
  });

  group('session state from the Rust stream', () {
    test('a session that fails is exposed as broken and recovers on the next event', () async {
      core.sessionState = SessionStateKind.established;
      controller = makeController();
      await controller.initialize();
      expect(controller.isSessionBroken, isFalse);

      core.sessionState = SessionStateKind.failed;
      await pumpEventQueue();
      expect(controller.isSessionBroken, isTrue);
      expect(controller.isSessionFailed, isTrue);
      expect(controller.isEstablished, isFalse);

      core.sessionState = SessionStateKind.established;
      await pumpEventQueue();
      expect(controller.isSessionBroken, isFalse);
      expect(controller.isEstablished, isTrue);
    });

    test('needing a new handshake is broken but not failed, and not established', () async {
      core.sessionState = SessionStateKind.established;
      controller = makeController();
      await controller.initialize();

      core.needsRehandshake = true;
      await pumpEventQueue();

      expect(controller.isSessionBroken, isTrue);
      expect(controller.isSessionFailed, isFalse);
      expect(controller.isEstablished, isFalse);
    });

    test('a session dropped by lock stops counting as established', () async {
      core.sessionState = SessionStateKind.established;
      controller = makeController();
      await controller.initialize();

      core.dropSession();
      await pumpEventQueue();

      expect(controller.isEstablished, isFalse);
      expect(controller.isSessionBroken, isFalse);
    });

    test('a failed session already published before the chat opened is shown on open', () async {
      core.sessionState = SessionStateKind.failed;
      final service = MessageReceptionService(core: core, router: router);
      await pumpEventQueue();
      controller = ChatController(
        core: core,
        router: router,
        contactId: contact,
        receptionService: service,
        recorder: recorder,
        player: player,
      );

      await controller.initialize();

      expect(controller.isSessionBroken, isTrue);
      await service.dispose();
    });

    test('reconnectSession resets the session and publishes the new INIT', () async {
      core.sessionState = SessionStateKind.failed;
      core.resetSessionResult = SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: Uint8List.fromList([4, 4]),
      );
      controller = makeController();
      await controller.initialize();

      await controller.reconnectSession();

      expect(core.resetSessionCalls, [contact.deviceId]);
      expect(transport.sendCalls.any((b) => listEquals(b, [4, 4])), isTrue);
      expect(controller.isReconnecting, isFalse);
      expect(controller.sessionError, isNull);
    });

    test('reconnectSession failure becomes sessionError, not exception', () async {
      core.sessionState = SessionStateKind.failed;
      core.resetSessionError = StateError('banco trancado');
      controller = makeController();
      await controller.initialize();

      await controller.reconnectSession();

      expect(controller.sessionError, isNotNull);
      expect(controller.isReconnecting, isFalse);
    });

    test('reconnectSession twice at once resets only once', () async {
      core.sessionState = SessionStateKind.failed;
      controller = makeController();
      await controller.initialize();

      await Future.wait([controller.reconnectSession(), controller.reconnectSession()]);

      expect(core.resetSessionCalls, hasLength(1));
    });
  });

  test('initialize keeps handshaking', () async {
    core.sessionState = SessionStateKind.handshaking;
    controller = makeController();

    await controller.initialize();

    expect(controller.isEstablished, isFalse);
  });

  test('initialize drains the outbox once, through the reception service', () async {
    core.sessionState = SessionStateKind.established;
    core.pendingToFlush = [
      SealedMessageDto(messageId: 42, bytes: Uint8List.fromList([5, 5, 5])),
    ];
    controller = makeController();

    await controller.initialize();
    await pumpEventQueue();

    expect(transport.sendCalls.where((b) => listEquals(b, [5, 5, 5])), hasLength(1));
    expect(core.markSentCalls, [42]);
  });

  test('useLan with established session', () async {
    core.sessionState = SessionStateKind.established;
    final lan = _FakeLanTransport();
    router = P2PTransportRouter(core: core, transportFactory: (_, _) => lan);
    controller = makeController();
    await controller.initialize();

    expect(controller.activeTransport, ActiveTransportType.lanDirect);
    await controller.sendFile('/tmp/documento.pdf');

    expect(core.startSendFileUseLan, [true]);
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

  test('failed send stays pending: sendText does not mark as sent nor throw', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();
    await controller.initialize();
    transport.sendError = StateError('conexão LAN indisponível');

    await controller.sendText('oi, bob');

    expect(core.markSentCalls, isEmpty);
    expect(core.requeueCalls, hasLength(1), reason: 'a linha `sending` precisa voltar à fila');
    expect(controller.connectionError, isNotNull);
  });

  test('failed send stays pending: sendReaction does not mark as sent nor throw', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();
    await controller.initialize();
    transport.sendError = StateError('conexão LAN indisponível');

    await controller.sendReaction(targetMessageId: 1, emoji: '👍');

    expect(core.markSentCalls, isEmpty);
    expect(core.requeueCalls, hasLength(1), reason: 'a linha `sending` precisa voltar à fila');
    expect(controller.connectionError, isNotNull);
  });

  test('failed markMessageSent after a delivered send is not reported as a connection error', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();
    await controller.initialize();
    core.failMarkSent = true;

    await controller.sendText('oi, bob');

    expect(transport.sendCalls, hasLength(1));
    expect(controller.connectionError, isNull);
  });

  test('successful send clears a stale send error', () async {
    core.sessionState = SessionStateKind.established;
    controller = makeController();
    await controller.initialize();
    transport.sendError = StateError('x');
    await controller.sendText('a');
    expect(controller.connectionError, isNotNull);

    transport.sendError = null;
    await controller.sendText('b');

    expect(controller.connectionError, isNull);
  });

  test('failed send stays pending: flushPending keeps every message pending when the connection is down', () async {
    core.outgoingHandshake = null;
    core.feedHandshakeResponse = null;
    core.establishOnFeedHandshake = true;
    core.pendingToFlush = [
      SealedMessageDto(messageId: 1, bytes: Uint8List.fromList([7])),
      SealedMessageDto(messageId: 2, bytes: Uint8List.fromList([8])),
    ];
    controller = makeController();
    await controller.initialize();
    transport.sendError = StateError('conexão LAN indisponível');
    transport.sendErrorWhen = (b) => b.length == 1 && b[0] >= 7;

    transport.emitIncoming(Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Quem drena o outbox de fato é o MessageReceptionService, que já captura.
    expect(core.markSentCalls, isEmpty);
    expect(transport.sendCalls.where((b) => b[0] >= 7), isEmpty);
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
      MessageDto(
        id: 5,
        direction: MessageDirectionDto.incoming,
        kind: MessageKindDto.text,
        body: 'recebida',
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 123,
        isEphemeral: false,
        viewOnce: false,
        reactions: const [],
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

    test('startRecording with a failed session is refused with the session message', () async {
      core.sessionState = SessionStateKind.failed;
      controller = makeController();
      await controller.initialize();

      await controller.startRecording();

      expect(controller.isRecording, isFalse);
      expect(controller.voiceError, ChatController.sessionBrokenMessage);
      expect(recorder.startCalls, 0);
    });

    test('voice note recorded while the session failed is discarded, not sent', () async {
      core.sessionState = SessionStateKind.established;
      controller = makeController();
      await controller.initialize();
      await controller.startRecording();
      final raw = File('${tempDir.path}/gravada.ogg')..writeAsBytesSync([1, 2, 3]);
      recorder.pathToReturnOnStop = raw.path;
      core.sessionState = SessionStateKind.failed;

      await controller.stopRecordingAndSend();

      expect(controller.voiceError, ChatController.sessionBrokenMessage);
      expect(controller.isSendingVoice, isFalse);
      await pumpEventQueue();
      expect(raw.existsSync(), isFalse);
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
          viewOnce: false,
          reactions: const [],
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
            viewOnce: false,
            reactions: const [],
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
        viewOnce: false,
        reactions: const [],
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
    test('voiceNoteWav keeps a single decoded WAV, decoding each note on demand', () async {
      var fileId = Uint8List.fromList(List.filled(16, 4));
      core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(1),
              isComplete: true,
            ),
          );
      var decodeCalls = 0;
      core.decodeAudioToWavHandler = (_) {
        decodeCalls++;
        return Uint8List.fromList([decodeCalls]);
      };
      controller = makeController();
      await controller.initialize();

      MessageDto noteFor(Uint8List id) => MessageDto(
            id: id.first,
            direction: MessageDirectionDto.incoming,
            kind: MessageKindDto.voiceNote,
            body: '',
            audioFileId: id,
            deliveryState: DeliveryStateDto.delivered,
            createdAtUnixSecs: 0,
            isEphemeral: false,
            viewOnce: false,
            reactions: const [],
          );

      final first = noteFor(fileId);
      transport.emitIncomingFile(Uint8List.fromList([1]));
      for (var i = 0; i < 50 && !controller.isVoiceNoteReady(first); i++) {
        await pumpEventQueue(times: 10);
      }
      fileId = Uint8List.fromList(List.filled(16, 5));
      final second = noteFor(fileId);
      transport.emitIncomingFile(Uint8List.fromList([2]));
      for (var i = 0; i < 50 && !controller.isVoiceNoteReady(second); i++) {
        await pumpEventQueue(times: 10);
      }
      expect(decodeCalls, 0, reason: 'receber não decodifica WAV');

      await controller.play(first);
      await controller.play(first);
      expect(decodeCalls, 1, reason: 'a nota corrente fica em cache');

      await controller.play(second);
      expect(decodeCalls, 2);

      await controller.play(first);
      expect(decodeCalls, 3, reason: 'o WAV da primeira nota não foi retido');
    });

    test('voiceNoteWav guards against race conditions and deduplicates concurrent calls', () async {
      var fileId = Uint8List.fromList(List.filled(16, 10));
      core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(1),
              isComplete: true,
            ),
          );

      final noteACompleter = Completer<Uint8List>();
      var decodeCalls = 0;
      core.decodeAudioToWavHandler = (bytes) {
        decodeCalls++;
        if (bytes.first == 10) {
          return noteACompleter.future;
        }
        return Uint8List.fromList([bytes.first, 99]);
      };

      controller = makeController();
      await controller.initialize();

      MessageDto noteFor(Uint8List id) => MessageDto(
            id: id.first,
            direction: MessageDirectionDto.incoming,
            kind: MessageKindDto.voiceNote,
            body: '',
            audioFileId: id,
            deliveryState: DeliveryStateDto.delivered,
            createdAtUnixSecs: 0,
            isEphemeral: false,
            viewOnce: false,
            reactions: const [],
          );

      core.finishReceiveAudioHandler = (id, destPath) {
        File(destPath).writeAsBytesSync([id.first]);
        return Uint8List.fromList([id.first]);
      };

      final noteA = noteFor(fileId);
      transport.emitIncomingFile(Uint8List.fromList([1]));
      for (var i = 0; i < 50 && !controller.isVoiceNoteReady(noteA); i++) {
        await pumpEventQueue(times: 10);
      }

      fileId = Uint8List.fromList(List.filled(16, 20));
      final noteB = noteFor(fileId);
      transport.emitIncomingFile(Uint8List.fromList([2]));
      for (var i = 0; i < 50 && !controller.isVoiceNoteReady(noteB); i++) {
        await pumpEventQueue(times: 10);
      }

      // 1. Deduplicação concorrente para a mesma nota
      final futureA1 = controller.voiceNoteWav(noteA);
      final futureA2 = controller.voiceNoteWav(noteA);
      expect(decodeCalls, 1, reason: 'apenas uma decodificação FFI deve ser disparada');

      // 2. Dispara decodificação de noteB enquanto noteA ainda está pendente
      final futureB = controller.voiceNoteWav(noteB);
      final wavB = await futureB;
      expect(wavB, Uint8List.fromList([20, 99]));
      expect(decodeCalls, 2);

      // Conclui noteA depois de noteB
      noteACompleter.complete(Uint8List.fromList([10, 42]));
      final wavA1 = await futureA1;
      final wavA2 = await futureA2;
      expect(wavA1, Uint8List.fromList([10, 42]));
      expect(wavA2, Uint8List.fromList([10, 42]));

      // 3. Verifica proteção contra condição de corrida: como noteB foi a requisição mais recente,
      // noteA que terminou atrasada NÃO deve ter sobrescrito o cache.
      // Chamar voiceNoteWav(noteB) agora deve acertar o cache imediatamente sem novo decode.
      final cachedWavB = await controller.voiceNoteWav(noteB);
      expect(cachedWavB, Uint8List.fromList([20, 99]));
      expect(decodeCalls, 2, reason: 'noteB permaneceu no cache como requisição mais recente');
    });
  });

  group('generic file transfer (Phase 4)', () {
    test(
      'sendFile seals FILE_METADATA through control channel, pumps chunks and marks message as sent',
      () async {
        core.sessionState = SessionStateKind.established;
        final fileId = Uint8List.fromList(List.filled(16, 5));
        core.startSendFileHandler = (_) => SendFileStartedDto(
              fileId: fileId,
              sealedMetadata: Uint8List.fromList([8, 8, 8]),
              messageId: 77,
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
        controller = makeController();
        await controller.initialize();

        await controller.sendFile('/tmp/documento.pdf');

        expect(core.startSendFileCalls, ['/tmp/documento.pdf']);
        expect(
          transport.sendCalls,
          [Uint8List.fromList([8, 8, 8])],
          reason: 'FILE_METADATA vai pelo canal control',
        );
        expect(
          transport.sendFileCalls,
          [Uint8List.fromList([1]), Uint8List.fromList([2])],
          reason: 'símbolos vão pelo canal file na ordem de nextOutgoingWireChunk',
        );
        expect(core.markSentCalls, [77], reason: 'markMessageSent deve ser chamado com o message_id do DTO');
        expect(controller.isSendingFile, isFalse);
        expect(controller.fileError, isNull);
      },
    );

    group('interrupted transfer', () {
      final fileId = Uint8List.fromList(List.filled(16, 5));

      MessageDto pendingFileMessage() => MessageDto(
            id: 77,
            direction: MessageDirectionDto.outgoing,
            kind: MessageKindDto.text,
            body: 'documento.pdf',
            deliveryState: DeliveryStateDto.pending,
            createdAtUnixSecs: 1000,
            isEphemeral: false,
            viewOnce: false,
            reactions: const [],
          );

      /// Emissor esgotado e sem `FILE_FEEDBACK` à vista: o laço de envio fica
      /// girando, que é como o #54 trava depois que o socket cai.
      void stallPump() {
        core.messagesToReturn = [pendingFileMessage()];
        core.startSendFileHandler = (_) => SendFileStartedDto(
              fileId: fileId,
              sealedMetadata: Uint8List.fromList([8, 8, 8]),
              messageId: 77,
            );
        core.nextOutgoingWireChunkHandler = (_) => null;
        core.transferProgressHandler = (_) => TransferProgressDto(
              blocksDone: 0,
              totalBlocks: 1,
              bytesDone: BigInt.zero,
              isComplete: false,
            );
      }

      Future<void> dropTransportWhileSending() async {
        final sending = controller.sendFile('/tmp/documento.pdf');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(controller.isSendingFile, isTrue, reason: 'o laço está esperando feedback');
        transport.emitConnectionEvent(
          const TransportConnectionEvent(TransportConnectionState.failed, reason: 'socket caiu'),
        );
        await sending.timeout(const Duration(seconds: 2));
      }

      test('transport failure ends file pump', () async {
        core.sessionState = SessionStateKind.established;
        stallPump();
        controller = makeController();
        await controller.initialize();

        await dropTransportWhileSending();

        expect(controller.fileError, isNotNull);
        expect(controller.isSendingFile, isFalse);
        expect(core.markSentCalls, isEmpty, reason: 'o arquivo não chegou inteiro');
      });

      test('interrupted file shown as failed', () async {
        core.sessionState = SessionStateKind.established;
        stallPump();
        controller = makeController();
        await controller.initialize();

        await dropTransportWhileSending();

        expect(core.markFailedCalls, [77]);
        expect(
          controller.messages.singleWhere((m) => m.id == 77).deliveryState,
          DeliveryStateDto.failed,
        );
      });

      test('failed markMessageFailed still releases the sending flag', () async {
        core.sessionState = SessionStateKind.established;
        stallPump();
        controller = makeController();
        await controller.initialize();
        core.failMarkFailed = true;

        await dropTransportWhileSending();

        expect(controller.isSendingFile, isFalse);
        expect(controller.fileError, isNotNull);
      });
    });

    group('waiting for the transport', () {
      test('sendFile waits for the transport before creating the transfer', () async {
        core.sessionState = SessionStateKind.established;
        transport.connectGate = Completer<void>();
        controller = makeController();
        await controller.initialize();

        final sending = controller.sendFile('/tmp/documento.pdf');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(core.startSendFileCalls, isEmpty, reason: 'nada é criado antes de o par estar alcançável');
        expect(controller.isSendingFile, isTrue);

        transport.connectGate!.complete();
        await sending;

        expect(core.startSendFileCalls, ['/tmp/documento.pdf']);
      });

      test('sendFile gives up when the transport never connects', () async {
        core.sessionState = SessionStateKind.established;
        transport.connectGate = Completer<void>();
        controller = makeController(connectTimeout: const Duration(milliseconds: 100));
        await controller.initialize();

        await controller.sendFile('/tmp/documento.pdf');

        expect(core.startSendFileCalls, isEmpty, reason: 'sem mensagem pendente órfã no banco');
        expect(controller.fileError, isNotNull);
        expect(controller.isSendingFile, isFalse);
      });
    });

    test('sendFile failure becomes fileError, not exception', () async {
      core.sessionState = SessionStateKind.established;
      core.startSendFileHandler = (_) => throw StateError('sem sessão ativa');
      controller = makeController();
      await controller.initialize();

      await controller.sendFile('/tmp/qualquer.bin');

      expect(controller.fileError, isNotNull);
      expect(controller.isSendingFile, isFalse);
    });

    test('sendFile with a failed session is refused with the session message, creating nothing', () async {
      core.sessionState = SessionStateKind.failed;
      controller = makeController();
      await controller.initialize();

      await controller.sendFile('/tmp/qualquer.bin');

      expect(controller.fileError, ChatController.sessionBrokenMessage);
      expect(core.startSendFileCalls, isEmpty);
      expect(controller.isSendingFile, isFalse);
    });

    test('sendFile failing on a session that the stream has not reported yet says the session is the cause', () async {
      core.sessionState = SessionStateKind.established;
      controller = makeController();
      await controller.initialize();
      // O Rust derrubou a sessão no meio do envio; o evento ainda não chegou.
      core.startSendFileHandler = (_) {
        core.silentStatusOverride = SessionStateKind.failed;
        throw StateError('sessão falhou');
      };

      await controller.sendFile('/tmp/qualquer.bin');

      expect(controller.fileError, ChatController.sessionBrokenMessage);
    });

    test('sendFile failing on a healthy session keeps the generic message', () async {
      core.sessionState = SessionStateKind.established;
      core.startSendFileHandler = (_) => throw StateError('disco cheio');
      controller = makeController();
      await controller.initialize();

      await controller.sendFile('/tmp/qualquer.bin');

      expect(controller.fileError, 'Não foi possível enviar o arquivo.');
    });

    test('sendFile while already sending is a no-op (second call ignored)', () async {
      core.sessionState = SessionStateKind.established;
      // startSendFile nunca resolve — simula envio longo em andamento
      final completer = Completer<SendFileStartedDto>();
      core.startSendFileHandler = (_) => completer.future;
      controller = makeController();
      await controller.initialize();

      // Inicia o primeiro envio sem await (fica pendente)
      unawaited(controller.sendFile('/tmp/a.bin'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.isSendingFile, isTrue);

      // Segunda chamada deve ser ignorada silenciosamente
      await controller.sendFile('/tmp/b.bin');
      expect(core.startSendFileCalls, hasLength(1), reason: 'só a primeira chamada chegou ao Core');

      // Limpa — resolve a future pendente para não vazar
      completer.completeError(StateError('cancelado pelo teste'));
      await Future<void>.delayed(Duration.zero);
    });

    test(
      'incoming file chunks complete with FILE_COMPLETE sent back and path cached',
      () async {
        core.sessionState = SessionStateKind.established;
        final fileId = Uint8List.fromList(List.filled(16, 6));
        core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
              fileId: fileId,
              progress: TransferProgressDto(
                blocksDone: 1,
                totalBlocks: 1,
                bytesDone: BigInt.from(50),
                isComplete: true,
              ),
            );
        // Configura como arquivo genérico (não áudio): finishReceiveAudio vai
        // falhar (não há entrada de áudio) e o controller cai em
        // _finishReceivingFile.
        core.pendingFileOffersToReturn = [
          FileOfferDto(
            fileId: fileId,
            name: 'relatorio.pdf',
            fileSize: BigInt.from(50),
          ),
        ];
        controller = makeController();
        await controller.initialize();

        transport.emitIncomingFile(Uint8List.fromList([1]));
        // Aguarda o event loop processar _handleIncomingFileBytes,
        // _finishReceivingFile e o envio de FILE_COMPLETE (que são assíncronos).
        for (var i = 0;
            i < 50 && (core.finishReceiveFileCalls.isEmpty || transport.sendCalls.isEmpty);
            i++) {
          await pumpEventQueue(times: 10);
        }

        expect(core.finishReceiveFileCalls, hasLength(1),
            reason: 'finishReceiveFile deve ter sido chamado uma vez');
        // O destPath usa o nome sanitizado do arquivo.
        expect(core.finishReceiveFileCalls.single, contains('relatorio.pdf'));
        // FILE_COMPLETE (bytes [5,5,5] do fake) vai pelo canal control.
        expect(
          transport.sendCalls,
          [Uint8List.fromList([5, 5, 5])],
          reason: 'FILE_COMPLETE deve ser enviado de volta pelo canal control',
        );

        // isFileReady deve ser true para uma mensagem com esse fileId.
        final msg = MessageDto(
          id: 1,
          direction: MessageDirectionDto.incoming,
          kind: MessageKindDto.file,
          body: 'relatorio.pdf',
          audioFileId: fileId,
          deliveryState: DeliveryStateDto.delivered,
          createdAtUnixSecs: 0,
          isEphemeral: false,
          viewOnce: false,
          reactions: const [],
        );
        expect(controller.isFileReady(msg), isTrue,
            reason: 'caminho deve estar cacheado após recebimento completo');
        expect(controller.getReceivedFilePath(msg), isNotNull);
      },
    );

    test('incoming file with unknown fileId is silently ignored', () async {
      core.sessionState = SessionStateKind.established;
      final fileId = Uint8List.fromList(List.filled(16, 7));
      core.ingestIncomingWireBytesHandler = (_) => IngestedChunkDto(
            fileId: fileId,
            progress: TransferProgressDto(
              blocksDone: 1,
              totalBlocks: 1,
              bytesDone: BigInt.from(10),
              isComplete: true,
            ),
          );
      // Nenhuma oferta pendente de arquivo ou áudio — ambos os caminhos
      // devem falhar silenciosamente sem lançar exception.
      core.pendingFileOffersToReturn = [];
      controller = makeController();
      await controller.initialize();

      // Não deve lançar.
      transport.emitIncomingFile(Uint8List.fromList([1]));
      await pumpEventQueue(times: 20);

      expect(controller.fileError, isNull);
      expect(controller.connectionError, isNull);
    });

    test('loadUnconfirmedOffers loads unconfirmed file offers into state', () async {
      final fileId = Uint8List.fromList(List.filled(16, 9));
      final offer = FileOfferDto(
        fileId: fileId,
        name: 'huge_archive.zip',
        fileSize: BigInt.from(200 * 1024 * 1024),
      );
      core.unconfirmedFileOffersToReturn = [offer];
      controller = makeController();

      await controller.initialize();

      expect(controller.unconfirmedOffers, hasLength(1));
      expect(controller.unconfirmedOffers.first.name, 'huge_archive.zip');
      expect(controller.unconfirmedOffers.first.fileSize, BigInt.from(200 * 1024 * 1024));
    });

    test('loadUnconfirmedOffers exposes offersError and keeps the last valid list', () async {
      final offer = FileOfferDto(
        fileId: Uint8List.fromList(List.filled(16, 9)),
        name: 'huge_archive.zip',
        fileSize: BigInt.from(200 * 1024 * 1024),
      );
      core.unconfirmedFileOffersToReturn = [offer];
      controller = makeController();
      await controller.initialize();
      expect(controller.offersError, isNull);

      core.unconfirmedFileOffersError = FfiError.internal;
      await controller.loadUnconfirmedOffers();

      expect(controller.offersError, isNotNull);
      expect(controller.unconfirmedOffers, hasLength(1));

      core.unconfirmedFileOffersError = null;
      await controller.loadUnconfirmedOffers();

      expect(controller.offersError, isNull);
    });

    test('acceptFileOffer calls core, transmits initial feedback, and refreshes list', () async {
      final fileId = Uint8List.fromList(List.filled(16, 5));
      final offer = FileOfferDto(
        fileId: fileId,
        name: 'backup.iso',
        fileSize: BigInt.from(500 * 1024 * 1024),
      );
      core.unconfirmedFileOffersToReturn = [offer];
      core.fileFeedbackResponse = Uint8List.fromList([9, 9, 9]);
      controller = makeController();
      await controller.initialize();
      expect(controller.unconfirmedOffers, hasLength(1));

      // Ao aceitar, o fake core deve receber a chamada e simular a remoção da oferta pendente
      core.unconfirmedFileOffersToReturn = [];
      await controller.acceptFileOffer(fileId);

      expect(core.acceptFileOfferCalls, hasLength(1));
      expect(core.acceptFileOfferCalls.single, fileId);
      expect(core.fileFeedbackCalls, hasLength(1));
      expect(core.fileFeedbackCalls.single, fileId);
      expect(transport.sendCalls, [Uint8List.fromList([9, 9, 9])]);
      expect(controller.unconfirmedOffers, isEmpty);
    });

    test('acceptFileOffer failure surfaces through fileError and keeps the offer listed', () async {
      final fileId = Uint8List.fromList(List.filled(16, 9));
      core.unconfirmedFileOffersToReturn = [
        FileOfferDto(fileId: fileId, name: 'a.zip', fileSize: BigInt.from(200 * 1024 * 1024)),
      ];
      core.offerActionError = FfiError.storeFailure;
      controller = makeController();
      await controller.initialize();

      await controller.acceptFileOffer(fileId);

      expect(controller.fileError, 'Não foi possível aceitar o arquivo.');
      expect(core.fileFeedbackCalls, isEmpty, reason: 'sem recebimento não há feedback a mandar');
      expect(controller.unconfirmedOffers, hasLength(1));
    });

    test('rejecting a lost offer says it is gone instead of a generic failure', () async {
      core.offerActionError = FfiError.offerNotFound;
      controller = makeController();
      await controller.initialize();

      await controller.rejectFileOffer(Uint8List.fromList(List.filled(16, 9)));

      expect(controller.fileError, 'Esta oferta de arquivo não está mais disponível.');
    });

    test('rejectFileOffer calls core and refreshes list', () async {
      final fileId = Uint8List.fromList(List.filled(16, 8));
      final offer = FileOfferDto(
        fileId: fileId,
        name: 'huge_video.mov',
        fileSize: BigInt.from(1024 * 1024 * 1024),
      );
      core.unconfirmedFileOffersToReturn = [offer];
      controller = makeController();
      await controller.initialize();
      expect(controller.unconfirmedOffers, hasLength(1));

      core.unconfirmedFileOffersToReturn = [];
      await controller.rejectFileOffer(fileId);

      expect(core.rejectFileOfferCalls, hasLength(1));
      expect(core.rejectFileOfferCalls.single, fileId);
      expect(controller.unconfirmedOffers, isEmpty);
    });

    test('rejectFileOffer sends the sealed FILE_REJECT to the sender', () async {
      core.sealedRejectToReturn = Uint8List.fromList([4, 2, 4]);
      controller = makeController();
      await controller.initialize();

      await controller.rejectFileOffer(Uint8List.fromList(List.filled(16, 8)));

      expect(transport.sendCalls.where((b) => listEquals(b, [4, 2, 4])), hasLength(1));
      expect(controller.fileError, isNull);
    });

    test('rejectFileOffer without a session sends nothing and is not an error', () async {
      core.sealedRejectToReturn = null;
      controller = makeController();
      await controller.initialize();
      final before = transport.sendCalls.length;

      await controller.rejectFileOffer(Uint8List.fromList(List.filled(16, 8)));

      expect(transport.sendCalls.length, before);
      expect(controller.fileError, isNull);
    });

    test('rejectFileOffer keeps the local rejection when the notice fails to send', () async {
      core.sealedRejectToReturn = Uint8List.fromList([4, 2, 4]);
      controller = makeController();
      await controller.initialize();
      transport.sendError = StateError('canal fechado');
      transport.sendErrorWhen = (b) => listEquals(b, [4, 2, 4]);

      await controller.rejectFileOffer(Uint8List.fromList(List.filled(16, 8)));

      expect(core.rejectFileOfferCalls, hasLength(1));
      expect(controller.fileError, isNull);
    });

    test('a rejected outgoing file is listed with the rejected state', () async {
      core.messagesToReturn = [
        MessageDto(
          id: 1,
          direction: MessageDirectionDto.outgoing,
          kind: MessageKindDto.text,
          body: 'a.bin',
          deliveryState: DeliveryStateDto.rejected,
          createdAtUnixSecs: PlatformInt64Util.from(1),
          isEphemeral: false,
          viewOnce: false,
          reactions: const [],
        ),
      ];
      controller = makeController();

      await controller.initialize();

      expect(controller.messages.single.deliveryState, DeliveryStateDto.rejected);
    });
  });
}
