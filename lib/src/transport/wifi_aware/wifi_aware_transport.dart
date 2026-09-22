import 'dart:async';
import 'dart:typed_data';

import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/framing.dart' as ffi_framing;

import '../../discovery/beacon_id.dart';
import '../lan/lan_transport.dart' show FrameFn, ExtractFrameFn;
import '../p2p_transport.dart';
import '../selecting_p2p_transport.dart' show TransportReadiness;
import '../webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;
import 'wifi_aware_channel.dart';

const int _channelControl = 0x00;
const int _channelFile = 0x01;

/// [P2PTransport] concreto sobre Wi-Fi Aware (Android) — Fase 6, F4.
///
/// Diferente de BLE, carrega dados de verdade. Diferente de [LanTransport],
/// que abre duas conexões TCP (`control`/`file`), aqui há um único caminho
/// de dados por trás do plugin nativo — os dois canais lógicos são
/// multiplexados por mensagem: 1 byte de marcador (`_channelControl`/
/// `_channelFile`) antes de cada envelope, dentro do mesmo `wire::framing`
/// já usado no socket TCP local (reaproveitado, não uma terceira convenção
/// de enquadramento nova).
///
/// Papel ativo/passivo decidido pela mesma regra do handshake do protocolo
/// (`docs/protocol.md` §4), reaproveitando `Core.ensureSession` — mesma
/// convenção de `LanTransport`/`WebrtcP2PTransport`. O nome de serviço
/// publicado/assinado é o beacon em hex — mesma convenção do nome de
/// instância mDNS (`docs/protocol.md` §9.2), não uma terceira.
///
/// **Só um `WifiAwareTransport` por vez, no processo inteiro** —
/// `WifiAwarePlugin.kt` só acompanha uma sessão de descoberta e um caminho
/// de dados por vez (limitação de implementação, não da API do Android;
/// documentada aqui para não ser descoberta em produção). Não verificado em
/// hardware real (Fase 6, §5/§6 do relatório).
class WifiAwareTransport implements P2PTransport, TransportReadiness {
  WifiAwareTransport({
    required Core core,
    required ContactId contactId,
    WifiAwareChannel? channel,
    FrameFn? frame,
    ExtractFrameFn? extractFrame,
  })  : _core = core,
        _contactId = contactId,
        _channel = channel ?? MethodChannelWifiAwareChannel(),
        _frame = frame ?? ffi_framing.frameForLocalSocket,
        _extractFrame = extractFrame ?? ffi_framing.extractFrameFromLocalSocketBuffer {
    _sessionEstablished.future.ignore();
    unawaited(_refreshReachability());
  }

  final Core _core;
  final ContactId _contactId;
  final WifiAwareChannel _channel;
  final FrameFn _frame;
  final ExtractFrameFn _extractFrame;

  final _incomingController = StreamController<Uint8List>.broadcast();
  final _incomingFileController = StreamController<Uint8List>.broadcast();
  final _connectionEventsController = StreamController<TransportConnectionEvent>.broadcast();

  StreamSubscription<WifiAwareEvent>? _eventsSub;
  final _sessionEstablished = Completer<void>();
  Uint8List _buffer = Uint8List(0);
  bool _connectStarted = false;
  bool _isLikelyReachable = true;

  @override
  bool get isLikelyReachable => _isLikelyReachable;

  Future<void> _refreshReachability() async {
    try {
      _isLikelyReachable = await _channel.isSupported();
    } catch (_) {
      _isLikelyReachable = false;
    }
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
    final framed = await _frame(envelope: tagged);
    await _channel.send(framed);
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
        throw StateError('Wi-Fi Aware não suportado neste aparelho');
      }

      final beacons = await _core.discoveryBeacons(peerDeviceId: _contactId.deviceId);
      final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
      final weAreActive = status.outgoingHandshake != null;
      final serviceName = toHexInstanceName(beacons.advertiseBeacon);

      _eventsSub = _channel.events.listen(_handleEvent);

      if (weAreActive) {
        await _channel.subscribe(serviceName);
      } else {
        await _channel.publish(serviceName);
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

  void _handleEvent(WifiAwareEvent event) {
    switch (event) {
      case WifiAwareServiceDiscovered():
        break;
      case WifiAwareSessionEstablished():
        if (!_sessionEstablished.isCompleted) _sessionEstablished.complete();
      case WifiAwareDataReceived(:final bytes):
        unawaited(_ingest(bytes));
      case WifiAwareConnectionLost(:final reason):
        if (!_sessionEstablished.isCompleted) {
          _sessionEstablished.completeError(StateError(reason ?? 'caminho de dados perdido'));
        }
        _connectionEventsController.add(
          TransportConnectionEvent(TransportConnectionState.failed, reason: reason),
        );
    }
  }

  Future<void> _ingest(Uint8List chunk) async {
    _buffer = Uint8List.fromList([..._buffer, ...chunk]);
    try {
      while (true) {
        final (extracted, remaining) = await _extractFrame(buffer: _buffer);
        _buffer = remaining;
        if (extracted == null) break;
        if (extracted.isEmpty) continue;
        final channelByte = extracted[0];
        final payload = extracted.sublist(1);
        switch (channelByte) {
          case _channelControl:
            if (!_incomingController.isClosed) _incomingController.add(payload);
          case _channelFile:
            if (!_incomingFileController.isClosed) _incomingFileController.add(payload);
        }
      }
    } catch (_) {
      // Mesma armadilha do relatório da Fase 6, §4: um quadro rejeitado não
      // pode ser tentado de novo sobre o mesmo buffer — aqui a "conexão" é
      // o caminho de dados Wi-Fi Aware inteiro, então a resposta certa é
      // fechá-lo — mas só depois de avisar quem está ouvindo, nunca antes
      // (fechar primeiro fecharia `_connectionEventsController` e o evento
      // de falha nunca chegaria a ninguém).
      if (!_connectionEventsController.isClosed) {
        _connectionEventsController.add(
          const TransportConnectionEvent(
            TransportConnectionState.failed,
            reason: 'quadro rejeitado pelo enquadramento do caminho de dados',
          ),
        );
      }
      await close();
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
