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
      DiscoveryBeaconsDto(
        advertiseBeacon: advertiseBeacon,
        scanBeacons: scanBeacons,
        dialPreamble: advertiseBeacon,
        listenPreambles: scanBeacons,
      );

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

/// Atenção: voltar daqui não garante que o transporte já registrou a espera no
/// listener; os testes toleram qualquer ordem porque sonda e transporte
/// compartilham o `Completer` via `putIfAbsent`.
///
/// Espera o anúncio com limite de tempo, para uma regressão falhar o teste em
/// vez de travá-lo.
Future<void> _untilAdvertised(_FakeLanDiscovery discovery) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (discovery.advertiseCalls.isEmpty) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('anúncio nunca ocorreu');
    await Future<void>.delayed(Duration.zero);
  }
}

/// Anúncio que só termina quando o teste libera — simula o `advertise` lento
/// do mDNS real.
class _SlowAdvertiseDiscovery extends _FakeLanDiscovery {
  _SlowAdvertiseDiscovery(this._gate);

  final Future<void> _gate;

  @override
  Future<void> advertise({required String instanceName, required int port}) async {
    advertiseCalls.add((instanceName: instanceName, port: port));
    await _gate;
  }
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

  LanTransport passiveFor(LanListener listener, _FakeLanDiscovery discovery) => LanTransport(
        core: _FakeCore(
          myDeviceId_: _deviceIdPassive,
          advertiseBeacon: _beacon,
          scanBeacons: [_beacon],
          weAreActive: false,
        ),
        contactId: ContactId(_deviceIdActive),
        listener: listener,
        discovery: discovery,
        frame: _fakeFrame,
        extractFrame: _fakeExtractFrame,
        listNetworkInterfaces: _noNetworkInterfaces,
      );

  LanTransport activeFor(LanListener listener, _FakeLanDiscovery discovery) => LanTransport(
        core: _FakeCore(
          myDeviceId_: _deviceIdActive,
          advertiseBeacon: _beacon,
          scanBeacons: [_beacon],
          weAreActive: true,
        ),
        contactId: ContactId(_deviceIdPassive),
        listener: listener,
        discovery: discovery,
        frame: _fakeFrame,
        extractFrame: _fakeExtractFrame,
        listNetworkInterfaces: _noNetworkInterfaces,
      );

  /// Porta em que ninguém escuta — o que um registro mDNS de uma execução
  /// anterior do app deixa para trás.
  Future<int> deadPort() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  test('retries next announcement after a refused one', () async {
    final passiveDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();
    final passive = passiveFor(passiveListener, passiveDiscovery);
    final active = activeFor(activeListener, activeDiscovery);
    addTearDown(active.close);
    addTearDown(passive.close);

    final passiveConnect = passive.connect();
    await _untilAdvertised(passiveDiscovery);
    final announced = passiveDiscovery.advertiseCalls.single;

    final activeConnect = active.connect();
    final name = announced.instanceName;
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(instanceName: name, host: '127.0.0.1', port: await deadPort()),
    );
    // O registro velho chega primeiro e é recusado; o atual chega depois.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    activeDiscovery.emitDiscovered(
      LanPeer(instanceName: name, host: '127.0.0.1', port: announced.port),
    );

    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));
  });

  test('connect stays pending without a valid announcement and ends silently on close', () async {
    final discovery = _FakeLanDiscovery();
    final active = activeFor(activeListener, discovery);
    final events = <TransportConnectionState>[];
    active.connectionEvents.listen((e) => events.add(e.state));

    var completed = false;
    final connect = active.connect().then((_) => completed = true);
    await _emitOnceBrowsing(
      discovery,
      LanPeer(
        instanceName: toHexInstanceName(_beacon),
        host: '127.0.0.1',
        port: await deadPort(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(completed, isFalse);

    await active.close();
    await connect.timeout(const Duration(seconds: 5));
    expect(events, isNot(contains(TransportConnectionState.connected)));
    expect(events, isNot(contains(TransportConnectionState.failed)));
  });

  test('dials each announced port once', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = <Socket>[];
    server.listen(accepted.add);

    final discovery = _FakeLanDiscovery();
    final active = activeFor(activeListener, discovery);
    addTearDown(active.close);

    final connect = active.connect();
    final name = toHexInstanceName(_beacon);
    await _emitOnceBrowsing(
      discovery,
      LanPeer(instanceName: name, host: '127.0.0.1', port: server.port),
    );
    // Mesma porta anunciada por outro endereço (IPv4/IPv6) ou reemitida pelo
    // NSD: não pode virar um segundo par de conexões no listener do par.
    discovery.emitDiscovered(LanPeer(instanceName: name, host: 'localhost', port: server.port));
    discovery.emitDiscovered(LanPeer(instanceName: name, host: '127.0.0.1', port: server.port));
    await connect.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(accepted, hasLength(2)); // control + file, de um único par
  });

  test('ignores announcements of other peers', () async {
    final discovery = _FakeLanDiscovery();
    final active = activeFor(activeListener, discovery);
    var completed = false;
    final connect = active.connect().then((_) => completed = true);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    await _emitOnceBrowsing(
      discovery,
      LanPeer(instanceName: 'ff' * 16, host: '127.0.0.1', port: server.port),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(completed, isFalse);
    await active.close();
    await connect.timeout(const Duration(seconds: 5));
  });

  test('close cancels preamble wait', () async {
    final discovery = _FakeLanDiscovery();
    final transport = passiveFor(passiveListener, discovery);

    final connect = transport.connect();
    await _untilAdvertised(discovery);
    // Mesma espera que o transporte registrou (putIfAbsent devolve o Completer
    // já existente) — serve de sonda para saber se `close` a cancelou.
    final probe = passiveListener.waitForConnection(
      deviceId: _beacon,
      channel: LanChannel.control,
    );
    final probeCancelled = expectLater(probe, throwsA(isA<StateError>()));

    await transport.close();
    await connect;
    await probeCancelled;

    final next = passiveListener.waitForConnection(deviceId: _beacon, channel: LanChannel.control);
    expect(identical(next, probe), isFalse);
    passiveListener.cancelWait(deviceId: _beacon, channel: LanChannel.control);
    await next.then<void>((_) {}, onError: (Object _) {});
  });

  test('connection goes to live transport', () async {
    final deadDiscovery = _FakeLanDiscovery();
    final liveDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();

    final dead = passiveFor(passiveListener, deadDiscovery);
    final deadConnect = dead.connect();
    await _untilAdvertised(deadDiscovery);
    await dead.close();
    await deadConnect;

    final live = passiveFor(passiveListener, liveDiscovery);
    addTearDown(live.close);
    final liveConnect = live.connect();
    await _untilAdvertised(liveDiscovery);
    final announced = liveDiscovery.advertiseCalls.single;

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
    final activeConnect = active.connect();
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(instanceName: announced.instanceName, host: '127.0.0.1', port: announced.port),
    );

    await Future.wait([activeConnect, liveConnect]).timeout(const Duration(seconds: 5));
  });

  test('connect destroys sockets and stays silent when closed before pumping', () async {
    final discovery = _FakeLanDiscovery();
    final transport = passiveFor(passiveListener, discovery);
    final events = <TransportConnectionState>[];
    transport.connectionEvents.listen((e) => events.add(e.state));

    final connect = transport.connect();
    await _untilAdvertised(discovery);
    final announced = discovery.advertiseCalls.single;

    // Conexão chega e `close` ocorre antes de `connect` retomar: ambos acontecem
    // no mesmo turno do event loop em que a espera completa.
    final socketControl = await Socket.connect(InternetAddress.loopbackIPv4, announced.port);
    addTearDown(socketControl.destroy);
    final controlClosed = Completer<void>();
    socketControl.listen(
      (_) {},
      onDone: controlClosed.complete,
      onError: (Object _) {
        if (!controlClosed.isCompleted) controlClosed.complete();
      },
    );
    socketControl.add(encodePreamble(deviceId: _beacon, channel: LanChannel.control));
    await socketControl.flush();
    final socketFile = await Socket.connect(InternetAddress.loopbackIPv4, announced.port);
    addTearDown(socketFile.destroy);
    socketFile.add(encodePreamble(deviceId: _beacon, channel: LanChannel.file));
    await socketFile.flush();

    final closed = transport.close();
    await connect.timeout(const Duration(seconds: 5));
    await closed;
    await controlClosed.future.timeout(const Duration(seconds: 5));
    expect(events, isNot(contains(TransportConnectionState.connected)));
  });

  test('close during advertise leaves no orphan wait', () async {
    final gate = Completer<void>();
    final discovery = _SlowAdvertiseDiscovery(gate.future);
    final transport = passiveFor(passiveListener, discovery);

    final connect = transport.connect();
    await _untilAdvertised(discovery);
    await transport.close();
    gate.complete();
    await connect.timeout(const Duration(seconds: 5));

    // Nenhuma espera deve ter sobrado: a próxima recebe um Completer novo e
    // não herda o do transporte morto.
    final probe = passiveListener.waitForConnection(deviceId: _beacon, channel: LanChannel.control);
    final cancelled = expectLater(probe, throwsA(isA<StateError>()));
    passiveListener.cancelWait(deviceId: _beacon, channel: LanChannel.control);
    await cancelled;
  });

  test('late close does not cancel the wait of a newer transport', () async {
    final oldDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();
    final old = passiveFor(passiveListener, oldDiscovery);
    final oldConnect = old.connect();
    await _untilAdvertised(oldDiscovery);

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
    final activeConnect = active.connect();
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(
        instanceName: oldDiscovery.advertiseCalls.single.instanceName,
        host: '127.0.0.1',
        port: oldDiscovery.advertiseCalls.single.port,
      ),
    );
    await Future.wait([activeConnect, oldConnect]).timeout(const Duration(seconds: 5));

    // Um transporte mais novo registra a mesma chave; fechar o antigo agora não
    // pode cancelá-la.
    final newer = passiveListener.waitForConnection(deviceId: _beacon, channel: LanChannel.control);
    var newerFailed = false;
    unawaited(newer.then<void>((_) {}, onError: (Object _) => newerFailed = true));
    await old.close();
    await Future<void>.delayed(Duration.zero);
    expect(newerFailed, isFalse);
    passiveListener.cancelWait(deviceId: _beacon, channel: LanChannel.control);
  });

  /// Dois transportes reais conectados em 127.0.0.1 (o passivo é o lado
  /// observado nos testes de queda).
  Future<({LanTransport passive, LanTransport active})> connectedPair() async {
    final passiveDiscovery = _FakeLanDiscovery();
    final activeDiscovery = _FakeLanDiscovery();
    final passive = passiveFor(passiveListener, passiveDiscovery);
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
    await _untilAdvertised(passiveDiscovery);
    final announced = passiveDiscovery.advertiseCalls.single;
    final activeConnect = active.connect();
    await _emitOnceBrowsing(
      activeDiscovery,
      LanPeer(instanceName: announced.instanceName, host: '127.0.0.1', port: announced.port),
    );
    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));
    return (passive: passive, active: active);
  }

  Future<TransportConnectionEvent> firstFailed(LanTransport t) => t.connectionEvents
      .firstWhere((e) => e.state == TransportConnectionState.failed)
      .timeout(const Duration(seconds: 5));

  test('peer close publishes a single failed event', () async {
    final pair = await connectedPair();
    final failures = <TransportConnectionEvent>[];
    pair.passive.connectionEvents
        .where((e) => e.state == TransportConnectionState.failed)
        .listen(failures.add);

    await pair.active.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Os dois sockets do par caem, mas o transporte falha uma vez só.
    expect(failures, hasLength(1));
  });

  test('peer close on one channel only fails the whole transport', () async {
    final discovery = _FakeLanDiscovery();
    final passive = passiveFor(passiveListener, discovery);
    addTearDown(passive.close);
    final connect = passive.connect();
    await _untilAdvertised(discovery);
    final port = discovery.advertiseCalls.single.port;

    final control = await Socket.connect(InternetAddress.loopbackIPv4, port);
    control.add(encodePreamble(deviceId: _beacon, channel: LanChannel.control));
    await control.flush();
    final file = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(file.destroy);
    file.add(encodePreamble(deviceId: _beacon, channel: LanChannel.file));
    await file.flush();
    await connect.timeout(const Duration(seconds: 5));

    final failed = firstFailed(passive);
    control.destroy();
    await failed;

    await expectLater(passive.sendFile(Uint8List.fromList([1])), throwsStateError);
  });

  test('send after peer close fails without an unhandled Broken pipe', () async {
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final pair = await connectedPair();
      final failed = firstFailed(pair.passive);
      await pair.active.close();
      await failed;

      await expectLater(pair.passive.send(Uint8List.fromList([1, 2])), throwsStateError);
      await expectLater(pair.passive.sendFile(Uint8List.fromList([1, 2])), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (e, _) => uncaught.add(e));

    expect(uncaught, isEmpty);
  });

  test('local close does not publish failed', () async {
    final pair = await connectedPair();
    final events = <TransportConnectionState>[];
    pair.passive.connectionEvents.listen((e) => events.add(e.state));

    await pair.passive.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(events, isNot(contains(TransportConnectionState.failed)));
  });
}
