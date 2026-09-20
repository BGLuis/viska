import 'dart:async';
import 'dart:typed_data';

import 'package:viska/src/rust/ffi/core.dart';

import '../../discovery/beacon_id.dart';
import '../p2p_transport.dart';
import '../selecting_p2p_transport.dart' show TransportReadiness;
import '../webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;
import 'multipeer_channel.dart';

const int _channelControl = 0x00;
const int _channelFile = 0x01;

/// [P2PTransport] concreto sobre MultipeerConnectivity (iOS) — Fase 6, F5.
///
/// `MCSession.send` já entrega mensagens delimitadas (like o SCTP do
/// WebRTC) — **não** passa por `wire::framing`, diferente de
/// `LanTransport`/`WifiAwareTransport`. Os dois canais lógicos
/// (`control`/`file`) são multiplexados por 1 byte de marcador antes de
/// cada mensagem, mesma convenção de `WifiAwareTransport` — nenhuma
/// conexão TCP nem enquadramento por comprimento aqui, só o marcador.
///
/// Papel ativo/passivo decidido pela mesma regra do handshake do protocolo
/// (`docs/protocol.md` §4), reaproveitando `Core.ensureSession` — mesma
/// convenção do resto da Fase 6. O beacon (hex) vai no `discoveryInfo` do
/// anúncio, não no `serviceType` (fixo `"viska-p2p"` — decisão de
/// implementação flagged #5, ver `MultipeerPlugin.swift`).
///
/// **Só um `MultipeerTransport` por vez, no processo inteiro** — mesma
/// limitação de `WifiAwareTransport` (o plugin nativo só acompanha uma
/// sessão por vez). Não compila nesta máquina (sem Xcode) e não foi
/// verificado em hardware real — Fase 6, §5/§6 do relatório.
class MultipeerTransport implements P2PTransport, TransportReadiness {
  MultipeerTransport({
    required Core core,
    required ContactId contactId,
    MultipeerChannel? channel,
  })  : _core = core,
        _contactId = contactId,
        _channel = channel ?? MethodChannelMultipeerChannel() {
    unawaited(_refreshReachability());
  }

  final Core _core;
  final ContactId _contactId;
  final MultipeerChannel _channel;

  final _incomingController = StreamController<Uint8List>.broadcast();
  final _incomingFileController = StreamController<Uint8List>.broadcast();
  final _connectionEventsController = StreamController<TransportConnectionEvent>.broadcast();

  StreamSubscription<MultipeerEvent>? _eventsSub;
  final _sessionEstablished = Completer<void>();
  bool _connectStarted = false;
  bool _isLikelyReachable = true;

  @override
  bool get isLikelyReachable => _isLikelyReachable;

  Future<void> _refreshReachability() async {
    _isLikelyReachable = await _channel.isSupported();
  }

  @override
  Stream<Uint8List> get incoming => _incomingController.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFileController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEventsController.stream;

  @override
  Future<void> send(Uint8List envelope) => _sendOnChannel(_channelControl, envelope);

  @override
  Future<void> sendFile(Uint8List bytes) => _sendOnChannel(_channelFile, bytes);

  Future<void> _sendOnChannel(int channelByte, Uint8List payload) async {
    final tagged = Uint8List(1 + payload.length)
      ..[0] = channelByte
      ..setRange(1, 1 + payload.length, payload);
    await _channel.send(tagged);
  }

  @override
  Future<void> connect() async {
    if (_connectStarted) return;
    _connectStarted = true;
    _connectionEventsController.add(
      const TransportConnectionEvent(TransportConnectionState.connecting),
    );

    try {
      if (!await _channel.isSupported()) {
        throw StateError('MultipeerConnectivity não suportado');
      }

      final beacons = await _core.discoveryBeacons(peerDeviceId: _contactId.deviceId);
      final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
      final weAreActive = status.outgoingHandshake != null;
      final beaconHex = toHexInstanceName(beacons.advertiseBeacon);

      _eventsSub = _channel.events.listen(_handleEvent);

      if (weAreActive) {
        await _channel.browse(beaconHex);
      } else {
        await _channel.advertise(beaconHex);
      }

      await _sessionEstablished.future.timeout(const Duration(seconds: 30));
      _connectionEventsController.add(
        const TransportConnectionEvent(TransportConnectionState.connected),
      );
    } catch (e) {
      _connectionEventsController.add(
        TransportConnectionEvent(TransportConnectionState.failed, reason: e.toString()),
      );
      rethrow;
    }
  }

  void _handleEvent(MultipeerEvent event) {
    switch (event) {
      case MultipeerServiceDiscovered():
        break;
      case MultipeerSessionEstablished():
        if (!_sessionEstablished.isCompleted) _sessionEstablished.complete();
      case MultipeerDataReceived(:final bytes):
        _route(bytes);
      case MultipeerConnectionLost(:final reason):
        if (!_sessionEstablished.isCompleted) {
          _sessionEstablished.completeError(StateError(reason ?? 'sessão perdida'));
        }
        _connectionEventsController.add(
          TransportConnectionEvent(TransportConnectionState.failed, reason: reason),
        );
    }
  }

  void _route(Uint8List message) {
    if (message.isEmpty) return;
    final channelByte = message[0];
    final payload = message.sublist(1);
    switch (channelByte) {
      case _channelControl:
        if (!_incomingController.isClosed) _incomingController.add(payload);
      case _channelFile:
        if (!_incomingFileController.isClosed) _incomingFileController.add(payload);
    }
  }

  @override
  Future<void> close() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _channel.close();
    if (!_incomingController.isClosed) await _incomingController.close();
    if (!_incomingFileController.isClosed) await _incomingFileController.close();
    if (!_connectionEventsController.isClosed) await _connectionEventsController.close();
  }
}
