import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/discovery/ble/ble_advertiser.dart';
import 'package:viska/src/discovery/ble/ble_scanner.dart';
import 'package:viska/src/discovery/beacon_id.dart';
import 'package:viska/src/discovery/nearby_presence_service.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';

final _beaconAlice = Uint8List.fromList(List<int>.generate(16, (i) => i));
final _beaconBob = Uint8List.fromList(List<int>.generate(16, (i) => i + 100));
final _alice = ContactId(Uint8List.fromList(List<int>.filled(16, 0xA)));
final _bob = ContactId(Uint8List.fromList(List<int>.filled(16, 0xB)));

/// Só implementa o que `NearbyPresenceService` de fato chama.
class _FakeCore implements Core {
  final beaconsByContact = <ContactId, Uint8List>{};

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'Core.${invocation.memberName} não deveria ser chamado por este teste',
      );

  @override
  Future<DiscoveryBeaconsDto> discoveryBeacons({required List<int> peerDeviceId}) async {
    final beacon = beaconsByContact.entries
        .firstWhere((e) => _sameBytes(e.key.deviceId, peerDeviceId))
        .value;
    return DiscoveryBeaconsDto(advertiseBeacon: beacon, scanBeacons: [beacon]);
  }

  @override
  Future<ContactDto?> matchDiscoveredBeacon({required List<int> beacon}) async {
    for (final entry in beaconsByContact.entries) {
      if (_sameBytes(entry.value, beacon)) {
        return ContactDto(
          deviceId: entry.key.deviceId,
          signingPubkey: Uint8List(0),
          dhPubkey: Uint8List(0),
          pairedAtUnixSecs: 0,
          nickname: null,
        );
      }
    }
    return null;
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _FakeBleScanner implements BleScanner {
  final scanCalls = <List<String>>[];
  var stopScanCalls = 0;
  final _controller = StreamController<BleBeaconSighting>.broadcast();

  @override
  Stream<BleBeaconSighting> scan(List<String> serviceUuids) {
    scanCalls.add(serviceUuids);
    return _controller.stream;
  }

  @override
  Future<void> stopScan() async => stopScanCalls++;

  void emit(Uint8List beacon) => _controller.add(BleBeaconSighting(beacon: beacon));
}

class _FakeBleAdvertiser implements BleAdvertiser {
  var supported = true;
  final startAdvertisingCalls = <String>[];
  var stopAdvertisingCalls = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> startAdvertising(String serviceUuid) async {
    startAdvertisingCalls.add(serviceUuid);
  }

  @override
  Future<void> stopAdvertising() async => stopAdvertisingCalls++;
}

void main() {
  late _FakeCore core;
  late _FakeBleScanner scanner;
  late _FakeBleAdvertiser advertiser;
  late NearbyPresenceService service;

  setUp(() {
    core = _FakeCore()
      ..beaconsByContact[_alice] = _beaconAlice
      ..beaconsByContact[_bob] = _beaconBob;
    scanner = _FakeBleScanner();
    advertiser = _FakeBleAdvertiser();
    service = NearbyPresenceService(core: core, scanner: scanner, advertiser: advertiser);
  });

  tearDown(() async => service.dispose());

  test('emits contact when scanner finds known beacon', () async {
    await service.start(contacts: [_alice, _bob]);

    final received = <ContactId>[];
    service.nearby.listen(received.add);

    scanner.emit(_beaconBob);
    await Future<void>.delayed(Duration.zero);

    expect(received, [_bob]);
  });

  test('emits nothing for unknown beacon', () async {
    await service.start(contacts: [_alice, _bob]);

    final received = <ContactId>[];
    service.nearby.listen(received.add);

    scanner.emit(Uint8List.fromList(List<int>.filled(16, 0xFF)));
    await Future<void>.delayed(Duration.zero);

    expect(received, isEmpty);
  });

  test('scans for UUIDs of all provided contacts', () async {
    await service.start(contacts: [_alice, _bob]);

    expect(scanner.scanCalls, hasLength(1));
    final uuids = scanner.scanCalls.single.toSet();
    expect(uuids, {toBleServiceUuid(_beaconAlice), toBleServiceUuid(_beaconBob)});
  });

  test('advertises beacon of specified contact when supported', () async {
    await service.start(contacts: [_alice, _bob], advertiseFor: _alice);

    expect(advertiser.startAdvertisingCalls, [toBleServiceUuid(_beaconAlice)]);
  });

  test('does not advertise when advertiser is not supported', () async {
    advertiser.supported = false;

    await service.start(contacts: [_alice], advertiseFor: _alice);

    expect(advertiser.startAdvertisingCalls, isEmpty);
  });

  test('does not advertise when no contact is specified', () async {
    await service.start(contacts: [_alice, _bob]);

    expect(advertiser.startAdvertisingCalls, isEmpty);
  });

  test('re-advertises periodically to track epoch rotation', () {
    fakeAsync((async) {
      unawaited(service.start(contacts: [_alice], advertiseFor: _alice));
      async.elapse(Duration.zero);
      expect(advertiser.startAdvertisingCalls, hasLength(1));

      async.elapse(const Duration(minutes: 15));
      expect(advertiser.startAdvertisingCalls, hasLength(2));

      async.elapse(const Duration(minutes: 15));
      expect(advertiser.startAdvertisingCalls, hasLength(3));
    });
  });

  test('stop cancels scanning and advertising', () async {
    await service.start(contacts: [_alice], advertiseFor: _alice);

    await service.stop();

    expect(scanner.stopScanCalls, 1);
    expect(advertiser.stopAdvertisingCalls, greaterThanOrEqualTo(1));
  });
}
