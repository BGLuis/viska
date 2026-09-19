import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/chat/chat_controller.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

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
  Future<List<ContactDto>> listContacts() => throw UnimplementedError();

  @override
  Future<Uint8List> myQrPayload() => throw UnimplementedError();

  @override
  Future<ContactDto> pairFromQr({required List<int> payload}) => throw UnimplementedError();

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
}

class _FakeP2PTransport implements P2PTransport {
  final sendCalls = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Future<void> connect() async {}

  @override
  Future<void> send(Uint8List envelope) async => sendCalls.add(envelope);

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;

  @override
  Future<void> close() async {}

  void emitIncoming(Uint8List bytes) => _incoming.add(bytes);
  void emitConnectionEvent(TransportConnectionEvent event) => _connectionEvents.add(event);
}

void main() {
  late ContactId contact;
  late _FakeCore core;
  late _FakeP2PTransport transport;
  late P2PTransportRouter router;
  late ChatController controller;

  setUp(() {
    contact = ContactId(List.generate(16, (i) => i));
    core = _FakeCore();
    transport = _FakeP2PTransport();
    router = P2PTransportRouter(
      core: core,
      transportFactory: (_, _) => transport,
    );
  });

  test('initialize carrega o histórico existente', () async {
    core.messagesToReturn = [
      const MessageDto(
        id: 1,
        direction: MessageDirectionDto.incoming,
        body: 'oi',
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 1000,
      ),
    ];
    controller = ChatController(core: core, router: router, contactId: contact);

    await controller.initialize();

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.body, 'oi');
  });

  test('como iniciador: initialize publica a INIT pendente', () async {
    core.outgoingHandshake = Uint8List.fromList([9, 9, 9]);
    core.sessionState = SessionStateKind.handshaking;
    controller = ChatController(core: core, router: router, contactId: contact);

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(transport.sendCalls, [Uint8List.fromList([9, 9, 9])]);
    expect(controller.isEstablished, isFalse);
  });

  test('como respondedor: INIT recebida gera RESP publicada e estabelece a sessão', () async {
    core.outgoingHandshake = null; // respondedor
    core.feedHandshakeResponse = Uint8List.fromList([7, 7]);
    core.establishOnFeedHandshake = true;
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1, 2, 3])); // "INIT" do par
    await Future<void>.delayed(Duration.zero);

    expect(core.feedHandshakeCalls, [Uint8List.fromList([1, 2, 3])]);
    expect(transport.sendCalls, [Uint8List.fromList([7, 7])]);
    expect(controller.isEstablished, isTrue);
  });

  test('sessão estabelecida drena mensagens pendentes (flushPending)', () async {
    core.outgoingHandshake = null;
    core.feedHandshakeResponse = null;
    core.establishOnFeedHandshake = true;
    core.pendingToFlush = [
      SealedMessageDto(messageId: 42, bytes: Uint8List.fromList([5, 5, 5])),
    ];
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1])); // conclui o handshake
    await Future<void>.delayed(Duration.zero);

    expect(transport.sendCalls, [Uint8List.fromList([5, 5, 5])]);
    expect(core.markSentCalls, [42]);
  });

  test('sendText com sessão estabelecida envia na hora e marca como enviada', () async {
    core.sessionState = SessionStateKind.established;
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    await controller.sendText('oi, bob');

    expect(core.sealOutgoingTextCalls, ['oi, bob']);
    expect(transport.sendCalls, hasLength(1));
    expect(core.markSentCalls, hasLength(1));
  });

  test('sendText com sessão ainda não estabelecida só persiste (não envia)', () async {
    core.sessionState = SessionStateKind.handshaking;
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    await controller.sendText('mensagem adiantada');

    expect(core.sealOutgoingTextCalls, ['mensagem adiantada']);
    expect(transport.sendCalls, isEmpty);
    expect(core.markSentCalls, isEmpty);
  });

  test('sendText ignora texto vazio', () async {
    core.sessionState = SessionStateKind.established;
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    await controller.sendText('');

    expect(core.sealOutgoingTextCalls, isEmpty);
  });

  test('mensagem recebida com sessão estabelecida decifra e atualiza o histórico', () async {
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
        body: 'recebida',
        deliveryState: DeliveryStateDto.delivered,
        createdAtUnixSecs: 123,
      ),
    ];
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1, 1, 1]));
    await Future<void>.delayed(Duration.zero);

    expect(core.decryptIncomingCalls, [Uint8List.fromList([1, 1, 1])]);
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.body, 'recebida');
  });

  test('falha de AEAD (null) não derruba o controlador', () async {
    core.sessionState = SessionStateKind.established;
    core.decryptIncomingHandler = (_) => null;
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([9, 9]));
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages, isEmpty);
  });

  test('indicador de digitação (isTyping) não é adicionado ao histórico', () async {
    core.sessionState = SessionStateKind.established;
    core.decryptIncomingHandler = (_) => const IncomingMessageDto(
          messageId: null,
          body: '',
          isTyping: true,
          receivedAtUnixSecs: 0,
        );
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    transport.emitIncoming(Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages, isEmpty);
  });

  test('evento de conexão failed define connectionError', () async {
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();

    transport.emitConnectionEvent(
      const TransportConnectionEvent(TransportConnectionState.failed, reason: 'sem rota'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.connectionError, 'sem rota');
  });

  test('dispose cancela as assinaturas — eventos depois não afetam mais o estado', () async {
    controller = ChatController(core: core, router: router, contactId: contact);
    await controller.initialize();
    controller.dispose();

    transport.emitConnectionEvent(
      const TransportConnectionEvent(TransportConnectionState.failed, reason: 'tarde demais'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.connectionError, isNull);
  });
}
