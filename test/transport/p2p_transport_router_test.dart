import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/rust/ffi/core.dart';
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

void main() {
  group('P2PTransportRouter', () {
    late Map<ContactId, _FakeP2PTransport> created;
    late P2PTransportRouter router;

    setUp(() {
      created = {};
      router = P2PTransportRouter(
        // `Core` nunca é usado de verdade nestes testes — o router só o
        // repassa para a fábrica, que aqui ignora e devolve um dublê.
        core: _UnusedCore(),
        transportFactory: (core, contactId) {
          final transport = _FakeP2PTransport();
          created[contactId] = transport;
          return transport;
        },
      );
    });

    test('sendToContact creates and connects transport on first call', () async {
      final contact = ContactId([1, 2, 3]);
      await router.sendToContact(contact, Uint8List.fromList([9]));

      expect(created[contact]!.connectCalls, 1);
      expect(created[contact]!.sendCalls, [Uint8List.fromList([9])]);
    });

    test('sendFileToContact uses file channel, separate from sendToContact', () async {
      final contact = ContactId([1, 2, 3]);
      await router.sendFileToContact(contact, Uint8List.fromList([9]));

      expect(created[contact]!.connectCalls, 1);
      expect(created[contact]!.sendFileCalls, [Uint8List.fromList([9])]);
      expect(created[contact]!.sendCalls, isEmpty);
    });

    test('incomingFileFor receives only what file channel emits', () async {
      final contact = ContactId([4, 5, 6]);
      final received = <Uint8List>[];
      router.incomingFileFor(contact).listen(received.add);
      await Future<void>.delayed(Duration.zero);

      created[contact]!.emitIncomingFile(Uint8List.fromList([1]));
      created[contact]!.emitIncoming(Uint8List.fromList([2]));
      await Future<void>.delayed(Duration.zero);

      expect(received, [Uint8List.fromList([1])]);
    });

    test('subsequent calls for same contact reuse same transport', () async {
      final contact = ContactId([1, 2, 3]);
      await router.sendToContact(contact, Uint8List.fromList([1]));
      await router.sendToContact(contact, Uint8List.fromList([2]));

      expect(created, hasLength(1));
      expect(created[contact]!.connectCalls, 1, reason: 'connect só na primeira vez');
      expect(created[contact]!.sendCalls, hasLength(2));
    });

    test('different contacts receive different transports', () async {
      final alice = ContactId([1]);
      final bob = ContactId([2]);

      await router.sendToContact(alice, Uint8List.fromList([1]));
      await router.sendToContact(bob, Uint8List.fromList([2]));

      expect(created, hasLength(2));
      expect(created[alice], isNot(same(created[bob])));
    });

    test('incomingFor creates transport (and connects) even without sending anything beforehand', () async {
      final contact = ContactId([4, 5, 6]);
      final received = <Uint8List>[];
      router.incomingFor(contact).listen(received.add);

      // `incomingFor` é síncrono (devolve o Stream na hora), mas a criação
      // do transporte (e o `connect` disparado por ela) já aconteceu.
      expect(created, contains(contact));

      created[contact]!.emitIncoming(Uint8List.fromList([1, 2]));
      await Future<void>.delayed(Duration.zero);
      expect(received, [Uint8List.fromList([1, 2])]);
    });

    test('connectionEventsFor creates transport even without sending anything beforehand', () async {
      final contact = ContactId([7, 8, 9]);
      router.connectionEventsFor(contact);
      expect(created, contains(contact));
    });

    test('closeContact closes and forgets transport - next call creates a new one', () async {
      final contact = ContactId([1, 2, 3]);
      await router.sendToContact(contact, Uint8List.fromList([1]));
      final first = created[contact]!;

      await router.closeContact(contact);
      expect(first.closeCalls, 1);

      await router.sendToContact(contact, Uint8List.fromList([2]));
      expect(created[contact], isNot(same(first)), reason: 'deveria ser um transporte novo');
    });

    test('closeContact on contact without transport does not error', () async {
      await router.closeContact(ContactId([0, 0, 0]));
    });

    test('closeAll closes all registered transports', () async {
      final alice = ContactId([1]);
      final bob = ContactId([2]);
      await router.sendToContact(alice, Uint8List.fromList([1]));
      await router.sendToContact(bob, Uint8List.fromList([2]));

      await router.closeAll();

      expect(created[alice]!.closeCalls, 1);
      expect(created[bob]!.closeCalls, 1);
    });
  });
}

/// `Core` nunca é chamado nestes testes — só precisa existir para satisfazer
/// o construtor de `P2PTransportRouter`. Qualquer chamada real derrubaria o
/// teste alto e claro, o que é o comportamento certo: significaria que o
/// router está usando `Core` diretamente, quebrando a premissa de que ele só
/// repassa para a fábrica.
class _UnusedCore implements Core {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'Core não deveria ser chamado diretamente pelo P2PTransportRouter',
      );
}
