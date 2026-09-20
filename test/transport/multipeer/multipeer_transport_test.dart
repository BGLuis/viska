import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/multipeer/multipeer_channel.dart';
import 'package:viska/src/transport/multipeer/multipeer_transport.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

final _beacon = Uint8List.fromList(List<int>.generate(16, (i) => i));
final _deviceIdActive = Uint8List.fromList(List<int>.filled(16, 0xA));
final _deviceIdPassive = Uint8List.fromList(List<int>.filled(16, 0xB));

class _FakeCore implements Core {
  _FakeCore({required this.weAreActive});

  final bool weAreActive;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'Core.${invocation.memberName} não deveria ser chamado por este teste',
      );

  @override
  Future<DiscoveryBeaconsDto> discoveryBeacons({required List<int> peerDeviceId}) async =>
      DiscoveryBeaconsDto(advertiseBeacon: _beacon, scanBeacons: [_beacon]);

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
        outgoingHandshake: weAreActive ? Uint8List.fromList([1]) : null,
      );
}

class _FakeMultipeerChannel implements MultipeerChannel {
  var supported = true;
  String? advertisedBeaconHex;
  String? browsedBeaconHex;
  final sentBytes = <Uint8List>[];
  final _eventsController = StreamController<MultipeerEvent>.broadcast();
  var closeCalls = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> advertise(String beaconHex) async => advertisedBeaconHex = beaconHex;

  @override
  Future<void> browse(String beaconHex) async => browsedBeaconHex = beaconHex;

  @override
  Future<void> send(Uint8List bytes) async => sentBytes.add(bytes);

  @override
  Future<void> close() async => closeCalls++;

  @override
  Stream<MultipeerEvent> get events => _eventsController.stream;

  void emit(MultipeerEvent event) => _eventsController.add(event);
}

void main() {
  test('lado_ativo_procura_e_lado_passivo_anuncia_o_mesmo_beacon', () async {
    final activeChannel = _FakeMultipeerChannel();
    final passiveChannel = _FakeMultipeerChannel();

    final active = MultipeerTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: activeChannel,
    );
    final passive = MultipeerTransport(
      core: _FakeCore(weAreActive: false),
      contactId: ContactId(_deviceIdActive),
      channel: passiveChannel,
    );
    addTearDown(active.close);
    addTearDown(passive.close);

    final activeConnect = active.connect();
    final passiveConnect = passive.connect();
    await Future<void>.delayed(Duration.zero);

    expect(activeChannel.browsedBeaconHex, isNotNull);
    expect(passiveChannel.advertisedBeaconHex, activeChannel.browsedBeaconHex);

    activeChannel.emit(const MultipeerSessionEstablished());
    passiveChannel.emit(const MultipeerSessionEstablished());

    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));
  });

  test('dados_no_canal_control_e_file_sao_roteados_pelo_marcador', () async {
    final channel = _FakeMultipeerChannel();
    final transport = MultipeerTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
    );
    addTearDown(transport.close);

    final connectFuture = transport.connect();
    await Future<void>.delayed(Duration.zero);
    channel.emit(const MultipeerSessionEstablished());
    await connectFuture;

    final receivedControl = <Uint8List>[];
    final receivedFile = <Uint8List>[];
    transport.incoming.listen(receivedControl.add);
    transport.incomingFile.listen(receivedFile.add);

    await transport.send(Uint8List.fromList([1, 2, 3]));
    await transport.sendFile(Uint8List.fromList([9, 9]));
    expect(channel.sentBytes, hasLength(2));

    for (final sent in channel.sentBytes) {
      channel.emit(MultipeerDataReceived(sent));
    }
    await Future<void>.delayed(Duration.zero);

    expect(receivedControl, [Uint8List.fromList([1, 2, 3])]);
    expect(receivedFile, [Uint8List.fromList([9, 9])]);
  });

  test('isLikelyReachable_reflete_isSupported_do_canal', () async {
    final channel = _FakeMultipeerChannel()..supported = false;
    final transport = MultipeerTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
    );
    addTearDown(transport.close);

    expect(transport.isLikelyReachable, isTrue, reason: 'otimista antes da checagem terminar');
    await Future<void>.delayed(Duration.zero);
    expect(transport.isLikelyReachable, isFalse);
  });

  test('connect_falha_quando_nao_suportado', () async {
    final channel = _FakeMultipeerChannel()..supported = false;
    final transport = MultipeerTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
    );
    addTearDown(transport.close);

    await expectLater(transport.connect(), throwsA(isA<StateError>()));
    expect(channel.browsedBeaconHex, isNull);
  });

  test('connectionLost_antes_de_estabelecer_falha_o_connect', () async {
    final channel = _FakeMultipeerChannel();
    final transport = MultipeerTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
    );
    addTearDown(transport.close);

    final failedEvent = transport.connectionEvents.firstWhere(
      (event) => event.state == TransportConnectionState.failed,
    );
    final connectFuture = transport.connect();
    await Future<void>.delayed(Duration.zero);
    channel.emit(const MultipeerConnectionLost('par saiu de alcance'));

    await expectLater(connectFuture, throwsA(isA<StateError>()));
    await failedEvent.timeout(const Duration(seconds: 5));
  });
}
