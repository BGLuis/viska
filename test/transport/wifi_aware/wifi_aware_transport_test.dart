import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/webrtc_transport.dart';
import 'package:viska/src/transport/wifi_aware/wifi_aware_channel.dart';
import 'package:viska/src/transport/wifi_aware/wifi_aware_transport.dart';

final _beacon = Uint8List.fromList(List<int>.generate(16, (i) => i));
final _deviceIdActive = Uint8List.fromList(List<int>.filled(16, 0xA));
final _deviceIdPassive = Uint8List.fromList(List<int>.filled(16, 0xB));

/// Mesmo esquema simples de enquadramento de `lan_transport_test.dart` —
/// prefixo de 4 bytes de comprimento, sem depender de FFI real.
Future<Uint8List> _fakeFrame({required List<int> envelope}) async {
  final len = envelope.length;
  final out = Uint8List(4 + len);
  out.buffer.asByteData().setUint32(0, len);
  out.setRange(4, 4 + len, envelope);
  return out;
}

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

class _FakeWifiAwareChannel implements WifiAwareChannel {
  var supported = true;
  String? publishedServiceName;
  String? subscribedServiceName;
  final sentBytes = <Uint8List>[];
  final _eventsController = StreamController<WifiAwareEvent>.broadcast();
  var closeCalls = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> publish(String serviceName) async => publishedServiceName = serviceName;

  @override
  Future<void> subscribe(String serviceName) async => subscribedServiceName = serviceName;

  @override
  Future<void> send(Uint8List bytes) async => sentBytes.add(bytes);

  @override
  Future<void> close() async => closeCalls++;

  @override
  Stream<WifiAwareEvent> get events => _eventsController.stream;

  void emit(WifiAwareEvent event) => _eventsController.add(event);
}

void main() {
  test('active side subscribes and passive side publishes the same service name', () async {
    final activeChannel = _FakeWifiAwareChannel();
    final passiveChannel = _FakeWifiAwareChannel();

    final active = WifiAwareTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: activeChannel,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
    );
    final passive = WifiAwareTransport(
      core: _FakeCore(weAreActive: false),
      contactId: ContactId(_deviceIdActive),
      channel: passiveChannel,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
    );
    addTearDown(active.close);
    addTearDown(passive.close);

    final activeConnect = active.connect();
    final passiveConnect = passive.connect();
    await Future<void>.delayed(Duration.zero);

    expect(activeChannel.subscribedServiceName, isNotNull);
    expect(passiveChannel.publishedServiceName, activeChannel.subscribedServiceName);

    activeChannel.emit(const WifiAwareSessionEstablished());
    passiveChannel.emit(const WifiAwareSessionEstablished());

    await Future.wait([activeConnect, passiveConnect]).timeout(const Duration(seconds: 5));
  });

  test('data on control and file channels are routed by tag', () async {
    final channel = _FakeWifiAwareChannel();
    final transport = WifiAwareTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
    );
    addTearDown(transport.close);

    final connectFuture = transport.connect();
    await Future<void>.delayed(Duration.zero);
    channel.emit(const WifiAwareSessionEstablished());
    await connectFuture;

    final receivedControl = <Uint8List>[];
    final receivedFile = <Uint8List>[];
    transport.incoming.listen(receivedControl.add);
    transport.incomingFile.listen(receivedFile.add);

    // Envia pelos dois canais lógicos — o marcador vai embutido no
    // primeiro byte do envelope antes do enquadramento.
    await transport.send(Uint8List.fromList([1, 2, 3]));
    await transport.sendFile(Uint8List.fromList([9, 9]));
    expect(channel.sentBytes, hasLength(2));

    // Simula o eco desses dois quadros voltando pelo `EventChannel` — o
    // teste não depende de um par de verdade, só do roteamento por marcador.
    for (final framed in channel.sentBytes) {
      channel.emit(WifiAwareDataReceived(framed));
    }
    await Future<void>.delayed(Duration.zero);

    expect(receivedControl, [Uint8List.fromList([1, 2, 3])]);
    expect(receivedFile, [Uint8List.fromList([9, 9])]);
  });

  test('isLikelyReachable reflects channel isSupported', () async {
    final channel = _FakeWifiAwareChannel()..supported = false;
    final transport = WifiAwareTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
    );
    addTearDown(transport.close);

    expect(transport.isLikelyReachable, isTrue, reason: 'otimista antes da checagem terminar');
    await Future<void>.delayed(Duration.zero);
    expect(transport.isLikelyReachable, isFalse);
  });

  test('connect fails when not supported', () async {
    final channel = _FakeWifiAwareChannel()..supported = false;
    final transport = WifiAwareTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
    );
    addTearDown(transport.close);

    await expectLater(transport.connect(), throwsA(isA<StateError>()));
    expect(channel.subscribedServiceName, isNull);
  });

  test('connection is dropped when extract_frame rejects frame', () async {
    final channel = _FakeWifiAwareChannel();
    final transport = WifiAwareTransport(
      core: _FakeCore(weAreActive: true),
      contactId: ContactId(_deviceIdPassive),
      channel: channel,
      frame: _fakeFrame,
      extractFrame: _fakeExtractFrame,
    );
    addTearDown(transport.close);

    final connectFuture = transport.connect();
    await Future<void>.delayed(Duration.zero);
    channel.emit(const WifiAwareSessionEstablished());
    await connectFuture;

    final failedEvent = transport.connectionEvents.firstWhere(
      (event) => event.state == TransportConnectionState.failed,
    );

    final bogus = Uint8List(4);
    bogus.buffer.asByteData().setUint32(0, 999999);
    channel.emit(WifiAwareDataReceived(bogus));

    await failedEvent.timeout(const Duration(seconds: 5));

    // `close()` roda depois de emitir o evento de falha, não antes (bug já
    // corrigido) — espera a corrotina terminar em vez de checar no mesmo
    // microtask do evento.
    final stopwatch = Stopwatch()..start();
    while (channel.closeCalls == 0 && stopwatch.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(channel.closeCalls, greaterThanOrEqualTo(1));
  });
}
