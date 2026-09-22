import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/pairing/proximity/proximity_pairing_service.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _FakeProximityCore implements Core {
  _FakeProximityCore({
    required this.deviceId,
    required this.nickname,
    required this.sasToReturn,
  });

  final Uint8List deviceId;
  String? nickname;
  final String sasToReturn;

  List<int>? pairedPayload;
  String? pairedNickname;

  @override
  Future<Uint8List> myDeviceId() async => deviceId;

  @override
  Future<String?> myNickname() async => nickname;

  @override
  Future<Uint8List> myQrPayload() async =>
      Uint8List.fromList(List.generate(145, (i) => (deviceId[0] + i) % 256));

  @override
  Future<String> computeSasCode({required List<int> peerPayload}) async => sasToReturn;

  @override
  Future<ContactDto> pairFromQr({required List<int> payload, String? nickname}) async {
    pairedPayload = payload;
    pairedNickname = nickname;
    return ContactDto(
      deviceId: Uint8List.fromList(payload.take(16).toList()),
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 1000,
      nickname: nickname ?? 'Peer',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('DiscoveredProximityPeer equality and hashCode', () {
    test('peers with same id, address and port are equal and share hashCode', () {
      final addr = InternetAddress.loopbackIPv4;
      final peer1 = DiscoveredProximityPeer(
        id: 'peer-abc',
        name: 'Bob A',
        channel: 5,
        address: addr,
        port: 8080,
      );
      final peer2 = DiscoveredProximityPeer(
        id: 'peer-abc',
        name: 'Bob B',
        channel: 10,
        address: addr,
        port: 8080,
      );

      expect(peer1, equals(peer2));
      expect(peer1.hashCode, equals(peer2.hashCode));
    });

    test('peers with different id, address or port are not equal', () {
      final addr1 = InternetAddress.loopbackIPv4;
      final addr2 = InternetAddress('127.0.0.2');
      final peer1 = DiscoveredProximityPeer(
        id: 'peer-abc',
        name: 'Bob',
        channel: 5,
        address: addr1,
        port: 8080,
      );
      final peerDiffId = DiscoveredProximityPeer(
        id: 'peer-xyz',
        name: 'Bob',
        channel: 5,
        address: addr1,
        port: 8080,
      );
      final peerDiffAddr = DiscoveredProximityPeer(
        id: 'peer-abc',
        name: 'Bob',
        channel: 5,
        address: addr2,
        port: 8080,
      );
      final peerDiffPort = DiscoveredProximityPeer(
        id: 'peer-abc',
        name: 'Bob',
        channel: 5,
        address: addr1,
        port: 8081,
      );

      expect(peer1, isNot(equals(peerDiffId)));
      expect(peer1, isNot(equals(peerDiffAddr)));
      expect(peer1, isNot(equals(peerDiffPort)));
    });
  });

  group('ProximityPairingService lifecycle', () {
    test('start and stop updates broadcasting state and cleans up', () async {
      final core = _FakeProximityCore(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i)),
        nickname: 'Alice',
        sasToReturn: '123456',
      );
      final service = ProximityPairingService(core: core);
      addTearDown(service.dispose);

      expect(service.isBroadcasting, isFalse);

      await service.start();
      expect(service.isBroadcasting, isTrue);

      await service.stop();
      expect(service.isBroadcasting, isFalse);
    });
  });

  group('ProximityPairingService TCP bilateral handshake', () {
    late _FakeProximityCore coreA;
    late _FakeProximityCore coreB;
    late ProximityPairingService serviceA;
    late ProximityPairingService serviceB;

    setUp(() async {
      coreA = _FakeProximityCore(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 1)),
        nickname: 'Alice',
        sasToReturn: '456789',
      );
      coreB = _FakeProximityCore(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        nickname: 'Bob',
        sasToReturn: '456789',
      );

      serviceA = ProximityPairingService(core: coreA);
      serviceB = ProximityPairingService(core: coreB);

      await serviceA.start();
      await serviceB.start();
    });

    tearDown(() async {
      await serviceA.stop();
      await serviceB.stop();
      serviceA.dispose();
      serviceB.dispose();
    });

    test('both sides exchange payloads immediately and calculate identical SAS code', () async {
      final peersB = serviceB.discoveredPeers;
      unawaited(peersB.first);

      // Descobre a porta TCP do serviço B
      final peerBEntry = DiscoveredProximityPeer(
        id: 'bob-id',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: serviceB.tcpPort!,
      );

      final incomingRequestFuture = serviceB.incomingRequests.first;
      final confirmationFuture = serviceA.connectAndPair(peerBEntry);

      // Ambos devem receber seus respectivos pacotes e códigos SAS simultaneamente
      final incomingRequest = await incomingRequestFuture;
      final confirmation = await confirmationFuture;

      expect(incomingRequest.peerName, equals('Alice'));
      expect(incomingRequest.sasCode, equals('456789'));

      expect(confirmation.peerName, equals('Bob'));
      expect(confirmation.sasCode, equals('456789'));

      // Confirmação mútua: Alice confirma e Bob aceita
      final confirmFutureA = confirmation.confirm();
      final acceptFutureB = incomingRequest.accept();

      final contactA = await confirmFutureA;
      final contactB = await acceptFutureB;

      expect(contactA.nickname, equals('Bob'));
      expect(contactB.nickname, equals('Alice'));
      expect(coreA.pairedNickname, equals('Bob'));
      expect(coreB.pairedNickname, equals('Alice'));
    });

    test('Bob confirms before Alice and both complete cleanly without broken pipe', () async {
      final peerBEntry = DiscoveredProximityPeer(
        id: 'bob-id',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: serviceB.tcpPort!,
      );

      final incomingRequestFuture = serviceB.incomingRequests.first;
      final confirmationFuture = serviceA.connectAndPair(peerBEntry);

      final incomingRequest = await incomingRequestFuture;
      final confirmation = await confirmationFuture;

      // Bob aceita primeiro
      final acceptFutureB = incomingRequest.accept();
      // Pequeno atraso para simular o tempo de Alice conferir o código
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Alice confirma depois
      final confirmFutureA = confirmation.confirm();

      final contactB = await acceptFutureB;
      final contactA = await confirmFutureA;

      expect(contactB.nickname, equals('Alice'));
      expect(contactA.nickname, equals('Bob'));
    });

    test('Bob rejects request and Alice is notified via whenCancelled', () async {
      final peerBEntry = DiscoveredProximityPeer(
        id: 'bob-id',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: serviceB.tcpPort!,
      );

      final incomingRequestFuture = serviceB.incomingRequests.first;
      final confirmationFuture = serviceA.connectAndPair(peerBEntry);

      final incomingRequest = await incomingRequestFuture;
      final confirmation = await confirmationFuture;

      // Bob recusa o pareamento
      incomingRequest.reject();

      // Alice deve receber a notificação de cancelamento
      await expectLater(confirmation.whenCancelled, completes);

      // Se Alice tentar confirmar após a recusa, deve receber exceção amigável
      expect(
        () => confirmation.confirm(),
        throwsA(isA<ProximityPairingException>()),
      );
    });

    test('Alice cancels request and Bob is notified via whenCancelled', () async {
      final peerBEntry = DiscoveredProximityPeer(
        id: 'bob-id',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: serviceB.tcpPort!,
      );

      final incomingRequestFuture = serviceB.incomingRequests.first;
      final confirmationFuture = serviceA.connectAndPair(peerBEntry);

      final incomingRequest = await incomingRequestFuture;
      final confirmation = await confirmationFuture;

      // Alice cancela
      confirmation.cancel();

      // Bob deve ser notificado
      await expectLater(incomingRequest.whenCancelled, completes);

      // Se Bob tentar aceitar, deve receber exceção amigável
      expect(
        () => incomingRequest.accept(),
        throwsA(isA<ProximityPairingException>()),
      );
    });
  });
}
