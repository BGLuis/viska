import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/discovery/beacon_id.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/lan/lan_advertising_policy.dart';
import 'package:viska/src/transport/lan/lan_discovery.dart';
import 'package:viska/src/transport/lan/lan_listener.dart';
import 'package:viska/src/transport/lan/lan_transport.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

/// Beacon fixo de teste — a derivação em si já é coberta em
/// `rust/logic/src/discovery/beacon.rs`; aqui só importa que os dois lados
/// concordem no mesmo valor.
final _beacon = Uint8List.fromList(List<int>.generate(16, (i) => i));
final _deviceIdActive = Uint8List.fromList(List<int>.filled(16, 0xA));
final _deviceIdPassive = Uint8List.fromList(List<int>.filled(16, 0xB));

/// Enquadramento sem FFI real (indisponível em `flutter test`): prefixo de
/// 4 bytes de comprimento, big-endian — espelha `wire::framing` só o
/// suficiente para o teste, sem duplicar a lógica de rejeição de
/// comprimento absurdo (essa já está coberta em `rust/src/ffi/framing.rs`).
Future<Uint8List> _fakeFrame({required List<int> envelope}) async {
  final len = envelope.length;
  final out = Uint8List(4 + len);
  out.buffer.asByteData().setUint32(0, len);
  out.setRange(4, 4 + len, envelope);
  return out;
}

/// Evita que `LanTransport` faça I/O real de rede (`NetworkInterface.list`)
/// durante o teste — a checagem de alcançabilidade é só uma otimização
/// (Fase 6, F3) e não afeta nenhum destes cenários.
Future<List<NetworkInterface>> _noNetworkInterfaces() async => [];

Future<(Uint8List?, Uint8List)> _fakeExtractFrame({required List<int> buffer}) async {
  if (buffer.length < 4) return (null, Uint8List.fromList(buffer));
  final len = Uint8List.fromList(buffer.sublist(0, 4)).buffer.asByteData().getUint32(0);
  if (len > 1024) throw StateError('quadro absurdo — simula rejeição de extract_frame');
  final total = 4 + len;
  if (buffer.length < total) return (null, Uint8List.fromList(buffer));
  return (
    Uint8List.fromList(buffer.sublist(4, total)),
    Uint8List.fromList(buffer.sublist(total)),
  );
}

/// Só implementa o que `LanTransport` de fato chama — o resto arremessa
/// `UnimplementedError` de propósito (mesma convenção de
/// `webrtc_p2p_transport_test.dart`).
class _FakeCore implements Core {
  _FakeCore({
    required this.myDeviceId_,
    required this.advertiseBeacon,
    required this.scanBeacons,
    required this.weAreActive,
  });

  final Uint8List myDeviceId_;
  final Uint8List advertiseBeacon;
  final List<Uint8List> scanBeacons;
  final bool weAreActive;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'Core.${invocation.memberName} não deveria ser chamado por este teste',
      );

  @override
  Future<Uint8List> myDeviceId() async => myDeviceId_;

  @override
  Future<DiscoveryBeaconsDto> discoveryBeacons({required List<int> peerDeviceId}) async =>
      DiscoveryBeaconsDto(advertiseBeacon: advertiseBeacon, scanBeacons: scanBeacons);

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: weAreActive ? Uint8List.fromList([1]) : null,
      );
}

/// Dublê manual de [LanDiscovery] — `advertise` só registra a chamada;
/// `discovered` é alimentado manualmente pelo teste via [emitDiscovered].
class _FakeLanDiscovery implements LanDiscovery {
  final advertiseCalls = <({String instanceName, int port})>[];
  final _discoveredController = StreamController<LanPeer>.broadcast();
  var startBrowsingCalls = 0;
  var stopBrowsingCalls = 0;
  var stopAdvertisingCalls = 0;

  @override
  Future<void> advertise({required String instanceName, required int port}) async {
    advertiseCalls.add((instanceName: instanceName, port: port));
  }

  @override
  Future<void> stopAdvertising() async => stopAdvertisingCalls++;

  @override
  Stream<LanPeer> get discovered => _discoveredController.stream;

  @override
  Future<void> startBrowsing() async => startBrowsingCalls++;

  @override
  Future<void> stopBrowsing() async => stopBrowsingCalls++;

  @override
  Future<void> close() async => _discoveredController.close();

  void emitDiscovered(LanPeer peer) => _discoveredController.add(peer);
}

/// Espera `_findPeer` já ter assinado `discovery.discovered` (via
/// `startBrowsing`) antes de emitir — como é um `StreamController.broadcast`,
/// um evento emitido antes de haver assinante nenhum simplesmente se perde,
/// e `firstWhere` nunca completaria.
Future<void> _emitOnceBrowsing(_FakeLanDiscovery discovery, LanPeer peer) async {
  while (discovery.startBrowsingCalls == 0) {
    await Future<void>.delayed(Duration.zero);
  }
  discovery.emitDiscovered(peer);
}

void main() {
  late LanListener passiveListener;
  late LanListener activeListener;

  setUp(() {
    passiveListener = LanListener();
    activeListener = LanListener();
  });

  tearDown(() async {
    await passiveListener.close();
    await activeListener.close();
  });

  test('passive side advertises and active side dials when beacon is discovered', () async {
    final passiveDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();

    final passive = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdPassive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: false,
      ),
      contactId: ContactId(_deviceIdActive),
      listener: passiveListener,
      discovery: passiveDiscovery,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );

    final active = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdActive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: true,
      ),
      contactId: ContactId(_deviceIdPassive),
      listener: activeListener,
      discovery: activeDiscovery,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );

    final passiveConnect = passive.connect();
    // Espera o lado passivo anunciar antes de "descobrir" — só então
    // conhecemos a porta do listener dele.
    while (passiveDiscovery.advertiseCalls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final announced = passiveDiscovery.advertiseCalls.single;
    expect(announced.instanceName, toHexInstanceName(_beacon));

    final activeConnect = active.connect();
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(instanceName: announced.instanceName, host: '127.0.0.1', port: announced.port),
    );

    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));

    addTearDown(active.close);
    addTearDown(passive.close);
  });

  test('control and file channels are independent and carry unframed data', () async {
    final passiveDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();

    final passive = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdPassive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: false,
      ),
      contactId: ContactId(_deviceIdActive),
      listener: passiveListener,
      discovery: passiveDiscovery,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );
    final active = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdActive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: true,
      ),
      contactId: ContactId(_deviceIdPassive),
      listener: activeListener,
      discovery: activeDiscovery,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );
    addTearDown(active.close);
    addTearDown(passive.close);

    final passiveConnect = passive.connect();
    while (passiveDiscovery.advertiseCalls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final announced = passiveDiscovery.advertiseCalls.single;
    final activeConnect = active.connect();
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(instanceName: announced.instanceName, host: '127.0.0.1', port: announced.port),
    );
    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));

    final receivedControl = <Uint8List>[];
    final receivedFile = <Uint8List>[];
    passive.incoming.listen(receivedControl.add);
    passive.incomingFile.listen(receivedFile.add);

    await active.send(Uint8List.fromList([1, 2, 3]));
    await active.sendFile(Uint8List.fromList([9, 9]));

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(receivedControl, [Uint8List.fromList([1, 2, 3])]);
    expect(receivedFile, [Uint8List.fromList([9, 9])]);
  });

  test('connection is dropped when extract_frame rejects frame', () async {
    final passiveDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();

    final passive = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdPassive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: false,
      ),
      contactId: ContactId(_deviceIdActive),
      listener: passiveListener,
      discovery: passiveDiscovery,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );
    final active = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdActive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: true,
      ),
      contactId: ContactId(_deviceIdPassive),
      listener: activeListener,
      discovery: activeDiscovery,
      // O lado ativo enquadra com um comprimento que o `_fakeExtractFrame`
      // do lado passivo vai rejeitar como "absurdo".
      frame: ({required envelope}) async {
        final out = Uint8List(4);
        out.buffer.asByteData().setUint32(0, 999999);
        return out;
      },
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );
    addTearDown(active.close);
    addTearDown(passive.close);

    final passiveConnect = passive.connect();
    while (passiveDiscovery.advertiseCalls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final announced = passiveDiscovery.advertiseCalls.single;
    final activeConnect = active.connect();
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(instanceName: announced.instanceName, host: '127.0.0.1', port: announced.port),
    );
    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));

    final failedEvent = passive.connectionEvents.firstWhere(
      (event) => event.state == TransportConnectionState.failed,
    );

    await active.send(Uint8List.fromList([1]));

    await failedEvent.timeout(const Duration(seconds: 5));
  });

  test('isLikelyReachable becomes false when no network interface exists', () async {
    final transport = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdPassive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: false,
      ),
      contactId: ContactId(_deviceIdActive),
      listener: passiveListener,
      discovery: _FakeLanDiscovery(),
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );
    addTearDown(transport.close);

    // Otimista antes da primeira checagem terminar — nunca deveria pular um
    // candidato só porque a checagem ainda não voltou.
    expect(transport.isLikelyReachable, isTrue);

    await Future<void>.delayed(Duration.zero);

    expect(transport.isLikelyReachable, isFalse);
  });

  test('passive side does not advertise and fails fast when policy refuses', () async {
    final discovery = _FakeLanDiscovery();
    final transport = LanTransport(
      core: _FakeCore(
        myDeviceId_: _deviceIdPassive,
        advertiseBeacon: _beacon,
        scanBeacons: [_beacon],
        weAreActive: false,
      ),
      contactId: ContactId(_deviceIdActive),
      listener: passiveListener,
      discovery: discovery,
      policy: ActiveContactsAdvertisingPolicy(), // ninguém foi marcado ativo
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
      listNetworkInterfaces: _noNetworkInterfaces,
    );
    addTearDown(transport.close);

    await expectLater(transport.connect(), throwsA(isA<StateError>()));
    expect(discovery.advertiseCalls, isEmpty);
  });
}
