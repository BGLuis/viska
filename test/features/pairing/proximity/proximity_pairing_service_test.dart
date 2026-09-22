import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/pairing/proximity/proximity_pairing_service.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _FakeProximityCore implements Core {
  Uint8List deviceId = Uint8List.fromList(List.generate(16, (i) => i));
  String? nickname = 'Alice';

  @override
  Future<Uint8List> myDeviceId() async => deviceId;

  @override
  Future<String?> myNickname() async => nickname;

  @override
  Future<Uint8List> myQrPayload() async =>
      Uint8List.fromList(List.generate(145, (i) => i % 256));

  @override
  Future<String> computeSasCode({required List<int> peerPayload}) async => '654321';

  @override
  Future<ContactDto> pairFromQr({required List<int> payload, String? nickname}) async {
    return ContactDto(
      deviceId: Uint8List(16),
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
        name: 'Bob B', // Nome diferente não afeta identidade física
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
      final core = _FakeProximityCore();
      final service = ProximityPairingService(core: core);
      addTearDown(service.dispose);

      expect(service.isBroadcasting, isFalse);

      await service.start();
      expect(service.isBroadcasting, isTrue);

      await service.stop();
      expect(service.isBroadcasting, isFalse);
    });
  });
}
