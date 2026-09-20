import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/framing.dart' as ffi_framing;

import '../../discovery/beacon_id.dart';
import '../p2p_transport.dart';
import '../selecting_p2p_transport.dart' show TransportReadiness;
import '../webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;
import 'lan_advertising_policy.dart';
import 'lan_discovery.dart';
import 'lan_listener.dart';

/// Assinatura de `NetworkInterface.list` — extraída para que os testes
/// possam simular "sem rede local nenhuma" sem depender de que a máquina
/// de CI/teste tenha ou não uma interface de rede real.
typedef ListNetworkInterfacesFn = Future<List<NetworkInterface>> Function();

/// Assinatura de `frameForLocalSocket` — extraída para que os testes possam
/// substituir a chamada FFI real (indisponível em `flutter test`, mesmo
/// raciocínio de `JitteredOutbox.sampleJitter` em `outbox.dart`).
typedef FrameFn = Future<Uint8List> Function({required List<int> envelope});

/// Assinatura de `extractFrameFromLocalSocketBuffer` — mesmo raciocínio de
/// [FrameFn].
typedef ExtractFrameFn = Future<(Uint8List?, Uint8List)> Function({required List<int> buffer});

/// [P2PTransport] concreto sobre mDNS/DNS-SD (descoberta) + socket TCP
/// (dados) na mesma LAN — Fase 6, F1.
///
/// Papel ativo/passivo decidido pela mesma regra do handshake do protocolo
/// (`docs/protocol.md` §4, `PublicIdentity::is_before`), reaproveitando o
/// sinal que `Core.ensureSession` já devolve — mesma convenção de
/// [WebrtcP2PTransport]. O lado passivo ancora o [LanListener] (singleton do
/// processo) e anuncia via mDNS; o lado ativo procura por mDNS e disca duas
/// conexões TCP (`control`/`file`), cada uma identificada por um preâmbulo
/// (`lan_listener.dart`, decisão de implementação — não normativa em
/// `docs/protocol.md`).
class LanTransport implements P2PTransport, TransportReadiness {
  LanTransport({
    required Core core,
    required ContactId contactId,
    required LanListener listener,
    required LanDiscovery discovery,
    LanAdvertisingPolicy policy = const AlwaysAdvertisePolicy(),
    FrameFn? frame,
    ExtractFrameFn? extractFrame,
    ListNetworkInterfacesFn? listNetworkInterfaces,
  })  : _core = core,
        _contactId = contactId,
        _listener = listener,
        _discovery = discovery,
        _policy = policy,
        _frame = frame ?? ffi_framing.frameForLocalSocket,
        _extractFrame = extractFrame ?? ffi_framing.extractFrameFromLocalSocketBuffer,
        _listNetworkInterfaces = listNetworkInterfaces ?? NetworkInterface.list {
    unawaited(_refreshReachability());
  }

  final Core _core;
  final ContactId _contactId;
  final LanListener _listener;
  final LanDiscovery _discovery;
  final LanAdvertisingPolicy _policy;
  final FrameFn _frame;
  final ExtractFrameFn _extractFrame;
  final ListNetworkInterfacesFn _listNetworkInterfaces;

  /// Otimista até a primeira checagem terminar — nunca queremos pular um
  /// candidato só porque a checagem de interfaces de rede ainda não voltou.
  bool _isLikelyReachable = true;

  @override
  bool get isLikelyReachable => _isLikelyReachable;

  Future<void> _refreshReachability() async {
    try {
      final interfaces = await _listNetworkInterfaces();
      _isLikelyReachable = interfaces.any((i) => i.addresses.isNotEmpty);
    } catch (_) {
      // Falha ao listar interfaces não deveria nunca acontecer, mas se
      // acontecer, o otimismo é a resposta certa: não bloquear um
      // candidato por causa de uma checagem que não é o próprio transporte.
      _isLikelyReachable = true;
    }
  }

  final _incomingController = StreamController<Uint8List>.broadcast();
  final _incomingFileController = StreamController<Uint8List>.broadcast();
  final _connectionEventsController = StreamController<TransportConnectionEvent>.broadcast();

  LanConnection? _control;
  LanConnection? _file;
  bool _connectStarted = false;

  @override
  Stream<Uint8List> get incoming => _incomingController.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFileController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEventsController.stream;

  @override
  Future<void> send(Uint8List envelope) async {
    _control!.add(await _frame(envelope: envelope));
  }

  @override
  Future<void> sendFile(Uint8List bytes) async {
    _file!.add(await _frame(envelope: bytes));
  }

  @override
  Future<void> connect() async {
    if (_connectStarted) return;
    _connectStarted = true;
    _connectionEventsController.add(
      const TransportConnectionEvent(TransportConnectionState.connecting),
    );

    try {
      final beacons = await _core.discoveryBeacons(peerDeviceId: _contactId.deviceId);
      final myDeviceId = await _core.myDeviceId();
      final port = await _listener.ensureListening();

      final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
      final weAreActive = status.outgoingHandshake != null;

      if (weAreActive) {
        final peer = await _findPeer(beacons.scanBeacons);
        _control = await _dial(peer, LanChannel.control, myDeviceId);
        _file = await _dial(peer, LanChannel.file, myDeviceId);
      } else {
        if (!_policy.shouldAdvertise(_contactId)) {
          // Sem anúncio, o lado ativo nunca vai nos achar por mDNS — falha
          // rápido em vez de esperar o timeout inteiro de
          // `SelectingP2PTransport` para nada.
          throw StateError(
            'LanAdvertisingPolicy decidiu não anunciar este contato agora',
          );
        }
        final instanceName = toHexInstanceName(beacons.advertiseBeacon);
        await _discovery.advertise(instanceName: instanceName, port: port);
        _control = await _listener.waitForConnection(
          deviceId: _contactId.deviceId,
          channel: LanChannel.control,
        );
        _file = await _listener.waitForConnection(
          deviceId: _contactId.deviceId,
          channel: LanChannel.file,
        );
      }

      _pump(_control!, _incomingController);
      _pump(_file!, _incomingFileController);
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

  /// Procura, entre os peers anunciados na LAN agora, o primeiro cujo nome
  /// de instância bate com algum dos beacons da janela de três épocas.
  Future<LanPeer> _findPeer(List<Uint8List> scanBeacons) async {
    final wanted = scanBeacons.map(toHexInstanceName).toSet();
    await _discovery.startBrowsing();
    try {
      return await _discovery.discovered.firstWhere((peer) => wanted.contains(peer.instanceName));
    } finally {
      await _discovery.stopBrowsing();
    }
  }

  Future<LanConnection> _dial(LanPeer peer, LanChannel channel, Uint8List myDeviceId) async {
    final socket = await Socket.connect(peer.host, peer.port);
    socket.add(encodePreamble(deviceId: myDeviceId, channel: channel));
    await socket.flush();
    return LanConnection(socket: socket, incoming: socket);
  }

  /// Desenquadra `connection.incoming` e publica cada envelope extraído em
  /// `out`. Pausa a subscrição enquanto uma extração está em andamento (a
  /// chamada FFI é assíncrona) para nunca processar dois pedaços do mesmo
  /// buffer fora de ordem.
  void _pump(LanConnection connection, StreamController<Uint8List> out) {
    var buffer = Uint8List(0);
    late final StreamSubscription<Uint8List> sub;

    sub = connection.incoming.listen(
      (chunk) {
        sub.pause();
        unawaited(() async {
          buffer = Uint8List.fromList([...buffer, ...chunk]);
          try {
            while (true) {
              final (extracted, remaining) = await _extractFrame(buffer: buffer);
              buffer = remaining;
              if (extracted == null) break;
              if (!out.isClosed) out.add(extracted);
            }
            sub.resume();
          } catch (_) {
            // Armadilha do relatório da Fase 6, §4: `extract_frame` que
            // rejeita um quadro nunca deve ser tentado de novo sobre o
            // mesmo buffer — a única resposta correta é derrubar a conexão.
            await sub.cancel();
            connection.destroy();
            if (!_connectionEventsController.isClosed) {
              _connectionEventsController.add(
                const TransportConnectionEvent(
                  TransportConnectionState.failed,
                  reason: 'quadro rejeitado pelo enquadramento do socket local',
                ),
              );
            }
          }
        }());
      },
      onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
        connection.destroy();
      },
    );
  }

  @override
  Future<void> close() async {
    _listener.cancelWait(deviceId: _contactId.deviceId, channel: LanChannel.control);
    _listener.cancelWait(deviceId: _contactId.deviceId, channel: LanChannel.file);
    await _discovery.stopAdvertising();
    await _discovery.stopBrowsing();
    _control?.destroy();
    _file?.destroy();
    if (!_incomingController.isClosed) await _incomingController.close();
    if (!_incomingFileController.isClosed) await _incomingFileController.close();
    if (!_connectionEventsController.isClosed) await _connectionEventsController.close();
  }
}
