import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/chat/chat_controller.dart';
import 'package:viska/src/features/voice/voice_io.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/rust/frb_generated.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

/// Transporte em memória (Loopback) conectando dois pares diretamente
/// através de canais com buffer, simulando o transporte de rede entre Alice e Bob.
class LoopbackP2PTransport implements P2PTransport {
  LoopbackP2PTransport();

  LoopbackP2PTransport? peer;

  final _incoming = StreamController<Uint8List>();
  final _incomingFile = StreamController<Uint8List>();
  final _connectionEvents = StreamController<TransportConnectionEvent>();

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;

  @override
  Future<void> connect() async {
    _connectionEvents.add(
      const TransportConnectionEvent(TransportConnectionState.connected),
    );
  }

  @override
  Future<void> send(Uint8List envelope) async {
    scheduleMicrotask(() {
      peer?._incoming.add(envelope);
    });
  }

  @override
  Future<void> sendFile(Uint8List bytes) async {
    scheduleMicrotask(() {
      peer?._incomingFile.add(bytes);
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
    tempDirAlice = Directory.systemTemp.createTempSync('viska-e2e-alice');
    tempDirBob = Directory.systemTemp.createTempSync('viska-e2e-bob');

    coreAlice = await Core.open(appDir: tempDirAlice.path);
    coreBob = await Core.open(appDir: tempDirBob.path);
  });

  tearDown(() async {
    if (soPath == null) return;
    coreAlice.dispose();
    coreBob.dispose();

    tempDirAlice.deleteSync(recursive: true);
    tempDirBob.deleteSync(recursive: true);
  });

  test('E2E: Pareamento real entre duas instâncias e validação de Safety Number', () async {
    // 1. Geração de payloads de QR reais de 145 bytes a partir dos núcleos Rust
    final aliceQrPayload = await coreAlice.myQrPayload();
    final bobQrPayload = await coreBob.myQrPayload();

    expect(aliceQrPayload.length, 145);
    expect(bobQrPayload.length, 145);

    // 2. Simulação da exportação Base64 (mesmo formato que "Copiar código" e "Colar código" usam)
    final aliceBase64 = base64Encode(aliceQrPayload);
    final bobBase64 = base64Encode(bobQrPayload);

    // 3. Bob pareia com o código importado de Alice, sugerindo apelido
    final aliceBytesFromBob = base64Decode(aliceBase64);
    final contactAliceAtBob = await coreBob.pairFromQr(payload: aliceBytesFromBob, nickname: 'Alice');
    final aliceDeviceId = await coreAlice.myDeviceId();
    expect(contactAliceAtBob.deviceId, equals(aliceDeviceId));
    expect(contactAliceAtBob.nickname, equals('Alice'));

    // 4. Alice pareia com o código importado de Bob, sugerindo apelido
    final bobBytesFromAlice = base64Decode(bobBase64);
    final contactBobAtAlice = await coreAlice.pairFromQr(payload: bobBytesFromAlice, nickname: 'Bob');
    final bobDeviceId = await coreBob.myDeviceId();
    expect(contactBobAtAlice.deviceId, equals(bobDeviceId));
    expect(contactBobAtAlice.nickname, equals('Bob'));

    // 5. Verificação de persistência nos bancos SQLite isolados
    final aliceContacts = await coreAlice.listContacts();
    final bobContacts = await coreBob.listContacts();
    expect(aliceContacts.any((c) => _bytesEqual(c.deviceId, bobDeviceId) && c.nickname == 'Bob'), isTrue);
    expect(bobContacts.any((c) => _bytesEqual(c.deviceId, aliceDeviceId) && c.nickname == 'Alice'), isTrue);

    // 6. Atualização de apelido de contato e perfil próprio
    await coreAlice.setContactNickname(contactDeviceId: bobDeviceId, nickname: 'Bob Colega');
    final updatedAliceContacts = await coreAlice.listContacts();
    expect(updatedAliceContacts.firstWhere((c) => _bytesEqual(c.deviceId, bobDeviceId)).nickname, equals('Bob Colega'));

    expect(await coreAlice.myNickname(), isNull);
    await coreAlice.setMyNickname(nickname: 'Alice Santos');
    expect(await coreAlice.myNickname(), equals('Alice Santos'));

    // 7. Validação do código SAS de 6 dígitos idêntico entre os pares
    final sasAlice = await coreAlice.computeSasCode(peerPayload: bobQrPayload);
    final sasBob = await coreBob.computeSasCode(peerPayload: aliceQrPayload);
    expect(sasAlice.length, 6);
    expect(sasAlice, equals(sasBob));

    // 8. Validação criptográfica do Safety Number (cálculo pós-quântico de 60 dígitos formatados em 12 blocos de 5)
    final snAlice = await coreAlice.safetyNumber(contactDeviceId: bobDeviceId);
    final snBob = await coreBob.safetyNumber(contactDeviceId: aliceDeviceId);

    expect(snAlice.digits.replaceAll(' ', '').length, 60);
    expect(snBob.digits.replaceAll(' ', '').length, 60);
    expect(snAlice.digits, equals(snBob.digits), reason: 'Safety numbers devem ser rigorosamente idênticos dos dois lados');
  }, skip: skipE2E);

  test('E2E: Estabelecimento de sessão pós-quântica e troca de mensagens cifradas', () async {
    // 1. Pareamento prévio dos dois nós
    final alicePayload = await coreAlice.myQrPayload();
    final bobPayload = await coreBob.myQrPayload();

    final contactAliceAtBob = await coreBob.pairFromQr(payload: alicePayload);
    final contactBobAtAlice = await coreAlice.pairFromQr(payload: bobPayload);

    // 2. Criação do canal P2P em memória (Loopback)
    final transportAlice = LoopbackP2PTransport();
    final transportBob = LoopbackP2PTransport();
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

    // Identifica quem é iniciador (quem possui outgoingHandshake antes do handshake)
    final initialAliceStatus = await coreAlice.ensureSession(peerDeviceId: contactBobAtAlice.deviceId);
    final isAliceInitiator = initialAliceStatus.outgoingHandshake != null;

    final controllerAlice = ChatController(
      core: coreAlice,
      router: routerAlice,
      contactId: contactIdBob,
      recorder: _NoopVoiceRecorder(),
      player: _NoopVoicePlayer(),
    );
    final controllerBob = ChatController(
      core: coreBob,
      router: routerBob,
      contactId: contactIdAlice,
      recorder: _NoopVoiceRecorder(),
      player: _NoopVoicePlayer(),
    );

    // 3. Inicialização dos controladores e troca do handshake híbrido (X25519 + ML-KEM-768)
    await controllerAlice.initialize();
    await controllerBob.initialize();

    // Aguarda processamento do handshake e estabelecimento da sessão nos dois nós
    for (var i = 0; i < 50; i++) {
      if (controllerAlice.isEstablished && controllerBob.isEstablished) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(controllerAlice.isEstablished, isTrue, reason: 'Sessão da Alice deve estar estabelecida');
    expect(controllerBob.isEstablished, isTrue, reason: 'Sessão do Bob deve estar estabelecida');

    // 4. Configuração dos papéis (iniciador envia a primeira mensagem do ratchet)
    final initiatorController = isAliceInitiator ? controllerAlice : controllerBob;
    final responderController = isAliceInitiator ? controllerBob : controllerAlice;
    final initiatorName = isAliceInitiator ? 'Alice' : 'Bob';
    final responderName = isAliceInitiator ? 'Bob' : 'Alice';

    // 5. Iniciador envia mensagem de texto cifrada para o respondedor
    final msgInitiator = 'Olá de $initiatorName! Teste ponta a ponta pós-quântico funcionou!';
    await initiatorController.sendText(msgInitiator);

    // Aguarda a entrega, decifragem e persistência no nó receptor
    for (var i = 0; i < 50; i++) {
      if (responderController.messages.any((m) => m.body == msgInitiator)) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      responderController.messages.any((m) => m.body == msgInitiator && m.direction == MessageDirectionDto.incoming),
      isTrue,
      reason: '$responderName deve receber e decifrar a mensagem enviada por $initiatorName',
    );

    // 6. Respondedor responde para o iniciador
    final msgResponder = 'Olá de $responderName! Confirmo recebimento com sucesso!';
    await responderController.sendText(msgResponder);

    // Aguarda a entrega, decifragem e persistência no nó do iniciador
    for (var i = 0; i < 50; i++) {
      if (initiatorController.messages.any((m) => m.body == msgResponder)) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      initiatorController.messages.any((m) => m.body == msgResponder && m.direction == MessageDirectionDto.incoming),
      isTrue,
      reason: '$initiatorName deve receber e decifrar a resposta enviada por $responderName',
    );

    // 7. Verificação de persistência nos bancos de dados SQLite reais em disco
    final messagesInAliceDb = await coreAlice.listMessages(peerDeviceId: contactBobAtAlice.deviceId);
    final messagesInBobDb = await coreBob.listMessages(peerDeviceId: contactAliceAtBob.deviceId);

    expect(messagesInAliceDb.length, 2);
    expect(messagesInBobDb.length, 2);

    expect(messagesInAliceDb.map((m) => m.body), containsAll([msgInitiator, msgResponder]));
    expect(messagesInBobDb.map((m) => m.body), containsAll([msgInitiator, msgResponder]));

    // Limpeza dos controladores
    controllerAlice.dispose();
    controllerBob.dispose();
  }, skip: skipE2E);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
