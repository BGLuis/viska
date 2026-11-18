import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/chat/chat_controller.dart';
import 'package:viska/src/features/voice/voice_io.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/rust/frb_generated.dart';
import 'package:viska/src/transport/message_reception_service.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

/// Transporte em memória (Loopback) conectando dois pares diretamente
/// através de canais com buffer, simulando o transporte de rede entre Alice e Bob.
class _LoopbackP2PTransport implements P2PTransport {
  _LoopbackP2PTransport({this.failConnect = false});

  _LoopbackP2PTransport? peer;
  final bool failConnect;
  bool failSend = false;

  final _incoming = StreamController<Uint8List>();
  final _incomingFile = StreamController<Uint8List>();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;

  @override
  Future<void> connect() async {
    if (failConnect) {
      _connectionEvents.add(
        const TransportConnectionEvent(TransportConnectionState.failed, reason: 'rede indisponível'),
      );
      throw const TransportUnavailableException('rede indisponível');
    }
    _connectionEvents.add(
      const TransportConnectionEvent(TransportConnectionState.connected),
    );
  }

  void drop([String reason = 'conexão caiu']) {
    failSend = true;
    peer = null;
    if (!_connectionEvents.isClosed) {
      _connectionEvents.add(
        TransportConnectionEvent(TransportConnectionState.failed, reason: reason),
      );
    }
  }

  @override
  Future<void> send(Uint8List envelope) async {
    if (failSend) throw const TransportUnavailableException();
    scheduleMicrotask(() {
      final p = peer;
      if (p != null && !p._incoming.isClosed) {
        p._incoming.add(envelope);
      }
    });
  }

  @override
  Future<void> sendFile(Uint8List bytes) async {
    scheduleMicrotask(() {
      final p = peer;
      if (p != null && !p._incomingFile.isClosed) {
        p._incomingFile.add(bytes);
      }
    });
  }

  @override
  Future<void> close() async {
    await _incoming.close();
    await _incomingFile.close();
    await _connectionEvents.close();
  }
}

class _NoopVoiceRecorder implements VoiceRecorder {
  @override
  Future<void> start(String path) async {}

  @override
  Future<String?> stop() async => null;

  @override
  Future<void> dispose() async {}
}

class _NoopVoicePlayer implements VoicePlayer {
  @override
  Future<void> playBytes(Uint8List wavBytes) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  final candidates = [
    'rust/target/debug/libviska_core.so',
    'build/linux/x64/release/bundle/lib/libviska_core.so',
  ];
  final soPath = candidates.cast<String?>().firstWhere(
    (p) => File(p!).existsSync(),
    orElse: () => null,
  );
  final skipE2E = soPath == null
      ? 'libviska_core.so não encontrada. Execute `cargo build` no diretório rust/ para habilitar os testes E2E.'
      : null;

  late Directory tempDirAlice;
  late Directory tempDirBob;
  late Core coreAlice;
  late Core coreBob;

  setUpAll(() async {
    if (soPath != null) {
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(File(soPath).absolute.path));
      } catch (_) {
        // Já inicializado
      }
    }
  });

  setUp(() async {
    if (soPath == null) return;
    tempDirAlice = Directory.systemTemp.createTempSync('viska-bg-alice');
    tempDirBob = Directory.systemTemp.createTempSync('viska-bg-bob');

    coreAlice = await Core.open(appDir: tempDirAlice.path);
    coreBob = await Core.open(appDir: tempDirBob.path);
  });

  tearDown(() async {
    if (soPath == null) return;
    coreAlice.dispose();
    coreBob.dispose();

    if (tempDirAlice.existsSync()) {
      tempDirAlice.deleteSync(recursive: true);
    }
    if (tempDirBob.existsSync()) {
      tempDirBob.deleteSync(recursive: true);
    }
  });

  test(
    'E2E: message sent while peer has no ChatController alive is received and persisted in SQLite (Issue #3)',
    () async {
      // 1. Pareamento prévio dos dois nós
      final alicePayload = await coreAlice.myQrPayload();
      final bobPayload = await coreBob.myQrPayload();

      final contactAliceAtBob = await coreBob.pairFromQr(payload: alicePayload, nickname: 'Alice');
      final contactBobAtAlice = await coreAlice.pairFromQr(payload: bobPayload, nickname: 'Bob');

      // 2. Canal P2P em memória (Loopback) entre Alice e Bob
      final transportAlice = _LoopbackP2PTransport();
      final transportBob = _LoopbackP2PTransport();
      transportAlice.peer = transportBob;
      transportBob.peer = transportAlice;

      final routerAlice = P2PTransportRouter(
        core: coreAlice,
        transportFactory: (_, _) => transportAlice,
      );
      final routerBob = P2PTransportRouter(
        core: coreBob,
        transportFactory: (_, _) => transportBob,
      );

      final contactIdBob = ContactId(contactBobAtAlice.deviceId);
      final contactIdAlice = ContactId(contactAliceAtBob.deviceId);

      // Identifica quem é o iniciador ANTES de disparar o handshake de fundo
      final initialAliceStatus = await coreAlice.ensureSession(peerDeviceId: contactBobAtAlice.deviceId);
      final isAliceInitiator = initialAliceStatus.outgoingHandshake != null;

      final senderCore = isAliceInitiator ? coreAlice : coreBob;
      final receiverCore = isAliceInitiator ? coreBob : coreAlice;
      final senderRouter = isAliceInitiator ? routerAlice : routerBob;
      final receiverRouter = isAliceInitiator ? routerBob : routerAlice;
      final senderPeerContactId = isAliceInitiator ? contactIdBob : contactIdAlice;
      final receiverPeerContactId = isAliceInitiator ? contactIdAlice : contactIdBob;
      final senderPeerDeviceId = isAliceInitiator ? contactBobAtAlice.deviceId : contactAliceAtBob.deviceId;
      final receiverPeerDeviceId = isAliceInitiator ? contactAliceAtBob.deviceId : contactBobAtAlice.deviceId;
      final senderName = isAliceInitiator ? 'Alice' : 'Bob';
      final receiverName = isAliceInitiator ? 'Bob' : 'Alice';

      // 3. Inicialização do MessageReceptionService em nível de aplicação nos dois nós
      final receptionAlice = MessageReceptionService(
        core: coreAlice,
        router: routerAlice,
        tempDirProvider: () async => tempDirAlice.path,
      );
      final receptionBob = MessageReceptionService(
        core: coreBob,
        router: routerBob,
        tempDirProvider: () async => tempDirBob.path,
      );

      final senderReception = isAliceInitiator ? receptionAlice : receptionBob;
      final receiverReception = isAliceInitiator ? receptionBob : receptionAlice;

      await Future.wait([receptionAlice.start(), receptionBob.start()]);

      // 4. Aguarda estabelecimento da sessão pós-quântica em background
      for (var i = 0; i < 50; i++) {
        final sAlice = await coreAlice.ensureSession(peerDeviceId: contactBobAtAlice.deviceId);
        final sBob = await coreBob.ensureSession(peerDeviceId: contactAliceAtBob.deviceId);
        if (sAlice.state == SessionStateKind.established && sBob.state == SessionStateKind.established) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final sAlice = await coreAlice.ensureSession(peerDeviceId: contactBobAtAlice.deviceId);
      final sBob = await coreBob.ensureSession(peerDeviceId: contactAliceAtBob.deviceId);
      expect(sAlice.state, SessionStateKind.established);
      expect(sBob.state, SessionStateKind.established);

      // 5. O iniciador abre sua tela de conversa (ChatController ativo)
      //    O receptor NÃO tem nenhum ChatController ativo (conversa fechada)
      final controllerSender = ChatController(
        core: senderCore,
        router: senderRouter,
        receptionService: senderReception,
        contactId: senderPeerContactId,
        recorder: _NoopVoiceRecorder(),
        player: _NoopVoicePlayer(),
      );
      await controllerSender.initialize();

      // 6. Iniciador envia a primeira mensagem do ratchet para o receptor
      final msg1 = 'Olá $receiverName! Você está com a conversa fechada?';
      await controllerSender.sendText(msg1);

      // 7. Aguarda o pacote trafegar pela rede, ser decifrado pelo MessageReceptionService do receptor e persistido no SQLite
      for (var i = 0; i < 50; i++) {
        final msgs = await receiverCore.listMessages(peerDeviceId: receiverPeerDeviceId);
        if (msgs.any((m) => m.body == msg1)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final receiverMessages1 = await receiverCore.listMessages(peerDeviceId: receiverPeerDeviceId);
      expect(
        receiverMessages1.any((m) => m.body == msg1 && m.direction == MessageDirectionDto.incoming),
        isTrue,
        reason: '$receiverName deve receber e decifrar a mensagem no banco SQLite sem ter ChatController ativo',
      );

      // 8. O receptor abre a conversa pela primeira vez: o histórico deve conter a mensagem recebida em background
      final controllerReceiver = ChatController(
        core: receiverCore,
        router: receiverRouter,
        receptionService: receiverReception,
        contactId: receiverPeerContactId,
        recorder: _NoopVoiceRecorder(),
        player: _NoopVoicePlayer(),
      );
      await controllerReceiver.initialize();
      expect(controllerReceiver.messages.any((m) => m.body == msg1), isTrue);

      // 9. O receptor fecha a tela de conversa (dispose)
      controllerReceiver.dispose();

      // 10. Iniciador envia uma segunda mensagem enquanto o chat do receptor está fechado novamente
      final msg2 = 'Segunda mensagem enviada com o chat de $receiverName fechado de novo!';
      await controllerSender.sendText(msg2);

      for (var i = 0; i < 50; i++) {
        final msgs = await receiverCore.listMessages(peerDeviceId: receiverPeerDeviceId);
        if (msgs.any((m) => m.body == msg2)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final receiverMessages2 = await receiverCore.listMessages(peerDeviceId: receiverPeerDeviceId);
      expect(
        receiverMessages2.any((m) => m.body == msg2 && m.direction == MessageDirectionDto.incoming),
        isTrue,
        reason: 'Segunda mensagem recebida em background após dispose() do ChatController de $receiverName',
      );
      expect(receiverMessages2.length, 2);

      // 11. Agora o iniciador fecha a sua tela de conversa (dispose)
      controllerSender.dispose();

      // 12. O receptor abre o chat e responde — o iniciador deve receber no banco sem ter ChatController ativo!
      final controllerReceiver2 = ChatController(
        core: receiverCore,
        router: receiverRouter,
        receptionService: receiverReception,
        contactId: receiverPeerContactId,
        recorder: _NoopVoiceRecorder(),
        player: _NoopVoicePlayer(),
      );
      await controllerReceiver2.initialize();

      final msg3 = 'Resposta de $receiverName enquanto $senderName está com a conversa fechada!';
      await controllerReceiver2.sendText(msg3);

      for (var i = 0; i < 50; i++) {
        final msgs = await senderCore.listMessages(peerDeviceId: senderPeerDeviceId);
        if (msgs.any((m) => m.body == msg3)) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final senderMessages = await senderCore.listMessages(peerDeviceId: senderPeerDeviceId);
      expect(
        senderMessages.any((m) => m.body == msg3 && m.direction == MessageDirectionDto.incoming),
        isTrue,
        reason: '$senderName deve receber resposta em background sem ter ChatController ativo',
      );

      // Limpeza
      controllerReceiver2.dispose();
      await receptionAlice.dispose();
      await receptionBob.dispose();
      await transportAlice.close();
      await transportBob.close();
    },
    skip: skipE2E,
  );

  test(
    'E2E: pending text queued while transport is down is resent once on reconnect without peer traffic (Issue #96)',
    () async {
      // 1. Pareamento prévio dos dois nós
      final alicePayload = await coreAlice.myQrPayload();
      final bobPayload = await coreBob.myQrPayload();

      final contactAliceAtBob = await coreBob.pairFromQr(payload: alicePayload, nickname: 'Alice');
      final contactBobAtAlice = await coreAlice.pairFromQr(payload: bobPayload, nickname: 'Bob');

      final contactIdBob = ContactId(contactBobAtAlice.deviceId);
      final contactIdAlice = ContactId(contactAliceAtBob.deviceId);

      // 2. Canal P2P inicial conectado
      var currentAlice = _LoopbackP2PTransport();
      var currentBob = _LoopbackP2PTransport();
      currentAlice.peer = currentBob;
      currentBob.peer = currentAlice;

      var offline = false;
      final routerAlice = P2PTransportRouter(
        core: coreAlice,
        transportFactory: (_, _) =>
            offline ? _LoopbackP2PTransport(failConnect: true) : currentAlice,
      );
      final routerBob = P2PTransportRouter(
        core: coreBob,
        transportFactory: (_, _) =>
            offline ? _LoopbackP2PTransport(failConnect: true) : currentBob,
      );

      final receptionAlice = MessageReceptionService(
        core: coreAlice,
        router: routerAlice,
        tempDirProvider: () async => tempDirAlice.path,
      );
      final receptionBob = MessageReceptionService(
        core: coreBob,
        router: routerBob,
        tempDirProvider: () async => tempDirBob.path,
      );

      await Future.wait([receptionAlice.start(), receptionBob.start()]);

      // 3. Aguarda a sessão estabelecer nos dois lados e ambos terem cadeia ativa
      for (var i = 0; i < 50; i++) {
        final sAlice = await coreAlice.ensureSession(peerDeviceId: contactBobAtAlice.deviceId);
        final sBob = await coreBob.ensureSession(peerDeviceId: contactAliceAtBob.deviceId);
        if (sAlice.state == SessionStateKind.established &&
            sBob.state == SessionStateKind.established) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final controllerAlice = ChatController(
        core: coreAlice,
        router: routerAlice,
        receptionService: receptionAlice,
        contactId: contactIdBob,
        recorder: _NoopVoiceRecorder(),
        player: _NoopVoicePlayer(),
      );
      await controllerAlice.initialize();
      expect(controllerAlice.isEstablished, isTrue);

      // Garante que Alice já tenha cadeia de envio mesmo se tiver sido respondedora
      final initialAlice = await coreAlice.ensureSession(peerDeviceId: contactBobAtAlice.deviceId);
      if (initialAlice.outgoingHandshake == null) {
        final controllerBob = ChatController(
          core: coreBob,
          router: routerBob,
          receptionService: receptionBob,
          contactId: contactIdAlice,
          recorder: _NoopVoiceRecorder(),
          player: _NoopVoicePlayer(),
        );
        await controllerBob.initialize();
        await controllerBob.sendText('aquecimento');
        for (var i = 0; i < 50; i++) {
          if (controllerAlice.messages.any((m) => m.body == 'aquecimento')) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        controllerBob.dispose();
      }

      // 4. Derruba o transporte enquanto Alice envia uma mensagem (fica "Na fila")
      offline = true;
      currentAlice.drop();
      currentBob.drop();
      await pumpEventQueue();

      const queuedBody = 'mensagem na fila durante queda do transporte';
      await controllerAlice.sendText(queuedBody);
      for (var i = 0; i < 50; i++) {
        final match = controllerAlice.messages.where((m) => m.body == queuedBody);
        if (match.isNotEmpty && match.first.deliveryState == DeliveryStateDto.pending) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final queuedMsg = controllerAlice.messages.firstWhere((m) => m.body == queuedBody);
      expect(queuedMsg.deliveryState, DeliveryStateDto.pending);
      final bobBeforeReconnect = await coreBob.listMessages(peerDeviceId: contactAliceAtBob.deviceId);
      expect(bobBeforeReconnect.where((m) => m.body == queuedBody), isEmpty);

      // 5. Reconecta o transporte sem que Bob envie nada e sem reiniciar o app
      offline = false;
      final reconnectedAlice = _LoopbackP2PTransport();
      final reconnectedBob = _LoopbackP2PTransport();
      reconnectedAlice.peer = reconnectedBob;
      reconnectedBob.peer = reconnectedAlice;
      currentAlice = reconnectedAlice;
      currentBob = reconnectedBob;

      // Garante que nenhum sinal de sessão seria publicado (sessão já Established)
      expect(await coreAlice.connectSignal(peerDeviceId: contactBobAtAlice.deviceId), isNull);
      expect(await coreBob.connectSignal(peerDeviceId: contactAliceAtBob.deviceId), isNull);

      // Reconecta Bob primeiro para estar escutando o canal novo, sem enviar nada,
      // e então reconecta Alice via retomada de primeiro plano.
      receptionBob.handleAppResumed();
      receptionAlice.handleAppResumed();

      // 6. Aguarda a mensagem chegar em Bob uma única vez e mudar para Enviada/Entregue em Alice
      for (var i = 0; i < 50; i++) {
        final bobMsgs = await coreBob.listMessages(peerDeviceId: contactAliceAtBob.deviceId);
        final aliceMsgs = controllerAlice.messages.where((m) => m.body == queuedBody);
        if (bobMsgs.any((m) => m.body == queuedBody) &&
            aliceMsgs.isNotEmpty &&
            (aliceMsgs.first.deliveryState == DeliveryStateDto.sent ||
                aliceMsgs.first.deliveryState == DeliveryStateDto.delivered)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final bobMsgsAfter = await coreBob.listMessages(peerDeviceId: contactAliceAtBob.deviceId);
      expect(bobMsgsAfter.where((m) => m.body == queuedBody), hasLength(1));

      final aliceMsgAfter = controllerAlice.messages.firstWhere((m) => m.body == queuedBody);
      expect(
        aliceMsgAfter.deliveryState == DeliveryStateDto.sent ||
            aliceMsgAfter.deliveryState == DeliveryStateDto.delivered,
        isTrue,
        reason: 'a mensagem pendente deve sair da fila e virar Enviada (ou Entregue após recibo)',
      );

      controllerAlice.dispose();
      await receptionAlice.dispose();
      await receptionBob.dispose();
      await reconnectedAlice.close();
      await reconnectedBob.close();
    },
    skip: skipE2E,
  );
}
