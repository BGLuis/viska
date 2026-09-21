import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

/// Identificador de um dispositivo próximo descoberto na rede local.
class DiscoveredProximityPeer {
  const DiscoveredProximityPeer({
    required this.id,
    required this.name,
    required this.channel,
    required this.address,
    required this.port,
  });

  final String id;
  final String name;
  final int channel;
  final InternetAddress address;
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredProximityPeer &&
          id == other.id &&
          address == other.address &&
          port == other.port;

  @override
  int get hashCode => Object.hash(id, address, port);
}

/// Solicitação de pareamento recebida de um par próximo.
class IncomingProximityPairingRequest {
  IncomingProximityPairingRequest({
    required this.peerName,
    required this.channel,
    required this.sasCode,
    required this.accept,
    required this.reject,
  });

  final String peerName;
  final int channel;
  final String sasCode;
  final Future<ContactDto> Function() accept;
  final void Function() reject;
}

/// Sessão ativa de pareamento por proximidade.
class ProximityPairingConfirmation {
  ProximityPairingConfirmation({
    required this.peerName,
    required this.channel,
    required this.sasCode,
    required this.confirm,
    required this.cancel,
  });

  final String peerName;
  final int channel;
  final String sasCode;
  final Future<ContactDto> Function() confirm;
  final void Function() cancel;
}

/// Serviço de pareamento seguro por proximidade na rede local (LAN).
///
/// Implementa anúncio e descoberta direta via broadcast UDP local + conexão TCP
/// efêmera e autenticação presencial fora de banda (Short Authentication String - SAS
/// de 6 dígitos derivada do Safety Number pós-quântico).
class ProximityPairingService {
  ProximityPairingService({
    required this.core,
    this.broadcastPort = 53891,
  });

  final Core core;
  final int broadcastPort;

  static const List<int> _magicHeader = [0x56, 0x50, 0x01]; // 'V', 'P', v1

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;

  String? _myId;
  String _myName = 'Viska';
  int _myChannel = 12;

  final _peersController = StreamController<List<DiscoveredProximityPeer>>.broadcast();
  final Map<String, DiscoveredProximityPeer> _discoveredPeers = {};

  final _incomingRequestController = StreamController<IncomingProximityPairingRequest>.broadcast();

  Stream<List<DiscoveredProximityPeer>> get discoveredPeers => _peersController.stream;
  Stream<IncomingProximityPairingRequest> get incomingRequests => _incomingRequestController.stream;

  bool _isBroadcasting = false;
  bool get isBroadcasting => _isBroadcasting;

  /// Inicia a escuta e anúncio por proximidade.
  Future<void> start({String? customName}) async {
    await stop();

    final deviceIdBytes = await core.myDeviceId();
    _myId = base64UrlEncode(deviceIdBytes);
    final savedNickname = await core.myNickname();
    _myName = customName ?? savedNickname ?? 'Viska (${_myId!.substring(0, 4)})';

    // Canal determinístico derivado do device_id [1..32] para facilitar conferência visual
    _myChannel = (deviceIdBytes[0] % 32) + 1;

    // 1. Inicia ServerSocket TCP na porta efêmera
    _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _tcpServer!.listen(_handleIncomingConnection);

    // 2. Inicia socket UDP para descoberta por broadcast
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        broadcastPort,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen(_handleUdpPacket);
    } catch (_) {
      // Em ambientes com porta ocupada ou restrições de permissão UDP
      try {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _udpSocket!.broadcastEnabled = true;
        _udpSocket!.listen(_handleUdpPacket);
      } catch (_) {}
    }

    _isBroadcasting = true;

    // Anúncio periódico a cada 1.5s
    _broadcastTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _broadcastPresence();
    });
    _broadcastPresence();
  }

  /// Interrompe a busca e o anúncio.
  Future<void> stop() async {
    _isBroadcasting = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _udpSocket?.close();
    _udpSocket = null;

    await _tcpServer?.close();
    _tcpServer = null;

    _discoveredPeers.clear();
    if (!_peersController.isClosed) {
      _peersController.add([]);
    }
  }

  void _broadcastPresence() {
    if (_udpSocket == null || _tcpServer == null || _myId == null) return;

    final msg = jsonEncode({
      'type': 'viska_pair',
      'id': _myId,
      'name': _myName,
      'ch': _myChannel,
      'port': _tcpServer!.port,
    });
    final bytes = utf8.encode(msg);

    try {
      _udpSocket!.send(bytes, InternetAddress('255.255.255.255'), broadcastPort);
    } catch (_) {}
  }

  void _handleUdpPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _udpSocket == null) return;

    final datagram = _udpSocket!.receive();
    if (datagram == null) return;

    try {
      final text = utf8.decode(datagram.data);
      final json = jsonDecode(text) as Map<String, dynamic>;

      if (json['type'] != 'viska_pair') return;
      final peerId = json['id'] as String?;
      if (peerId == null || peerId == _myId) return;

      final peerName = json['name'] as String? ?? 'Dispositivo Próximo';
      final peerChannel = (json['ch'] as num?)?.toInt() ?? 1;
      final peerPort = (json['port'] as num?)?.toInt();
      if (peerPort == null || peerPort <= 0) return;

      final peer = DiscoveredProximityPeer(
        id: peerId,
        name: peerName,
        channel: peerChannel,
        address: datagram.address,
        port: peerPort,
      );

      _discoveredPeers[peerId] = peer;
      _peersController.add(_discoveredPeers.values.toList());
    } catch (_) {
      // Ignora pacotes de terceiros na rede
    }
  }

  /// Inicia o pareamento com um dispositivo selecionado.
  Future<ProximityPairingConfirmation> connectAndPair(DiscoveredProximityPeer peer) async {
    final socket = await Socket.connect(peer.address, peer.port, timeout: const Duration(seconds: 5));
    final completer = Completer<ProximityPairingConfirmation>();

    final myPayload = await core.myQrPayload();
    final myNameBytes = utf8.encode(_myName);

    // Envia preâmbulo + nosso payload + nosso apelido sugerido
    final buffer = BytesBuilder();
    buffer.add(_magicHeader);
    buffer.add(myPayload);
    buffer.addByte(myNameBytes.length);
    buffer.add(myNameBytes);
    socket.add(buffer.toBytes());
    await socket.flush();

    final receivedBytes = <int>[];

    socket.listen(
      (chunk) async {
        receivedBytes.addAll(chunk);

        // Preâmbulo (3 B) + Payload (145 B) + Comprimento do Nome (1 B) = 149 B mínimo
        if (receivedBytes.length < 149) return;

        // Valida cabeçalho
        if (receivedBytes[0] != _magicHeader[0] ||
            receivedBytes[1] != _magicHeader[1] ||
            receivedBytes[2] != _magicHeader[2]) {
          socket.destroy();
          if (!completer.isCompleted) {
            completer.completeError(Exception('Cabeçalho de protocolo inválido'));
          }
          return;
        }

        final peerPayload = Uint8List.fromList(receivedBytes.sublist(3, 148));
        final nameLen = receivedBytes[148];
        if (receivedBytes.length < 149 + nameLen) return;

        final peerNickname = utf8.decode(receivedBytes.sublist(149, 149 + nameLen));

        // Calcula o código SAS de 6 dígitos a partir do payload recebido
        final sasCode = await core.computeSasCode(peerPayload: peerPayload);

        if (!completer.isCompleted) {
          completer.complete(ProximityPairingConfirmation(
            peerName: peerNickname.isNotEmpty ? peerNickname : peer.name,
            channel: peer.channel,
            sasCode: sasCode,
            confirm: () async {
              socket.add([0x06]); // ACK de confirmação
              await socket.flush();
              await Future<void>.delayed(const Duration(milliseconds: 100));
              await socket.close();

              return core.pairFromQr(
                payload: peerPayload,
                nickname: peerNickname.isNotEmpty ? peerNickname : peer.name,
              );
            },
            cancel: () {
              socket.destroy();
            },
          ));
        }
      },
      onError: (err) {
        if (!completer.isCompleted) completer.completeError(err);
      },
    );

    return completer.future;
  }

  void _handleIncomingConnection(Socket socket) {
    final receivedBytes = <int>[];

    socket.listen(
      (chunk) async {
        receivedBytes.addAll(chunk);

        if (receivedBytes.length < 149) return;

        if (receivedBytes[0] != _magicHeader[0] ||
            receivedBytes[1] != _magicHeader[1] ||
            receivedBytes[2] != _magicHeader[2]) {
          socket.destroy();
          return;
        }

        final peerPayload = Uint8List.fromList(receivedBytes.sublist(3, 148));
        final nameLen = receivedBytes[148];
        if (receivedBytes.length < 149 + nameLen) return;

        final peerNickname = utf8.decode(receivedBytes.sublist(149, 149 + nameLen));
        final sasCode = await core.computeSasCode(peerPayload: peerPayload);

        // Notifica a interface sobre a solicitação de pareamento recebida
        _incomingRequestController.add(IncomingProximityPairingRequest(
          peerName: peerNickname.isNotEmpty ? peerNickname : 'Dispositivo Próximo',
          channel: _myChannel,
          sasCode: sasCode,
          accept: () async {
            // Responde com nosso payload de volta
            final myPayload = await core.myQrPayload();
            final myNameBytes = utf8.encode(_myName);
            final resp = BytesBuilder();
            resp.add(_magicHeader);
            resp.add(myPayload);
            resp.addByte(myNameBytes.length);
            resp.add(myNameBytes);
            socket.add(resp.toBytes());
            await socket.flush();

            // Salva o contato
            return core.pairFromQr(
              payload: peerPayload,
              nickname: peerNickname.isNotEmpty ? peerNickname : null,
            );
          },
          reject: () {
            socket.destroy();
          },
        ));
      },
      onError: (_) => socket.destroy(),
    );
  }

  void dispose() {
    stop();
    _peersController.close();
    _incomingRequestController.close();
  }
}
