import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

/// Exceção de controle para fluxos de pareamento por proximidade.
class ProximityPairingException implements Exception {
  const ProximityPairingException(this.message);
  final String message;

  @override
  String toString() => message;
}

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

/// Solicitação de pareamento recebida de um par próximo (papel: receptor).
class IncomingProximityPairingRequest {
  IncomingProximityPairingRequest({
    required this.peerName,
    required this.channel,
    required this.sasCode,
    required this.accept,
    required this.reject,
    this.whenCancelled,
  });

  final String peerName;
  final int channel;
  final String sasCode;
  final Future<ContactDto> Function() accept;
  final void Function() reject;
  final Future<void>? whenCancelled;
}

/// Sessão ativa de pareamento por proximidade (papel: solicitante).
class ProximityPairingConfirmation {
  ProximityPairingConfirmation({
    required this.peerName,
    required this.channel,
    required this.sasCode,
    required this.confirm,
    required this.cancel,
    this.whenCancelled,
  });

  final String peerName;
  final int channel;
  final String sasCode;
  final Future<ContactDto> Function() confirm;
  final void Function() cancel;
  final Future<void>? whenCancelled;
}

/// Serviço de pareamento seguro por proximidade na rede local (LAN).
///
/// Implementa anúncio e descoberta direta via broadcast UDP local, conexão TCP
/// efêmera e autenticação presencial fora de banda bilateral (Short Authentication
/// String - SAS de 6 dígitos derivada do Safety Number pós-quântico).
class ProximityPairingService {
  ProximityPairingService({
    required this.core,
    this.broadcastPort = 53891,
  });

  final Core core;
  final int broadcastPort;

  static const List<int> _magicHeader = [0x56, 0x50, 0x01]; // 'V', 'P', v1
  static const int _cmdConfirm = 0x06; // ACK de confirmação presencial
  static const int _cmdCancel = 0x15; // NAK / cancelamento explícito

  ServerSocket? _tcpServer;
  RawDatagramSocket? _udpSocket;
  Timer? _broadcastTimer;

  final Set<Socket> _activeSockets = {};

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

  @visibleForTesting
  int? get tcpPort => _tcpServer?.port;

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

  /// Interrompe a busca e o anúncio, encerrando todas as conexões ativas.
  Future<void> stop() async {
    _isBroadcasting = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;

    _udpSocket?.close();
    _udpSocket = null;

    await _tcpServer?.close();
    _tcpServer = null;

    for (final socket in _activeSockets.toList()) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _activeSockets.clear();

    _discoveredPeers.clear();
    if (!_peersController.isClosed) {
      _peersController.add([]);
    }
  }

  Uint8List _buildHandshakePacket(Uint8List payload, String name) {
    final nameBytes = utf8.encode(name);
    final buffer = BytesBuilder();
    buffer.add(_magicHeader);
    buffer.add(payload);
    buffer.addByte(nameBytes.length);
    buffer.add(nameBytes);
    return buffer.toBytes();
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
      if (!_peersController.isClosed) {
        _peersController.add(_discoveredPeers.values.toList());
      }
    } catch (_) {
      // Ignora pacotes de terceiros na rede
    }
  }

  /// Inicia o pareamento com um dispositivo selecionado (papel: solicitante).
  ///
  /// Conecta ao servidor TCP do dispositivo remoto, envia o handshake próprio e
  /// aguarda o handshake remoto de volta. Ambos exibem o código SAS de 6 dígitos
  /// em simultâneo.
  Future<ProximityPairingConfirmation> connectAndPair(DiscoveredProximityPeer peer) async {
    final socket = await Socket.connect(peer.address, peer.port, timeout: const Duration(seconds: 5));
    _activeSockets.add(socket);

    final handshakeCompleter = Completer<ProximityPairingConfirmation>();
    final remoteConfirmCompleter = Completer<void>();
    final remoteCancelledCompleter = Completer<void>();

    bool remoteConfirmed = false;
    bool isCompleted = false;
    bool isCancelled = false;

    // Envia preâmbulo + nosso payload + nosso apelido sugerido
    try {
      final myPayload = await core.myQrPayload();
      socket.add(_buildHandshakePacket(myPayload, _myName));
      await socket.flush();
    } catch (e) {
      _activeSockets.remove(socket);
      socket.destroy();
      rethrow;
    }

    final receivedBytes = <int>[];
    bool handshakeReceived = false;
    Uint8List? peerPayload;
    String peerNickname = '';

    socket.listen(
      (chunk) async {
        try {
          if (!handshakeReceived) {
            receivedBytes.addAll(chunk);
            if (receivedBytes.length < 149) return;

            // Valida cabeçalho
            if (receivedBytes[0] != _magicHeader[0] ||
                receivedBytes[1] != _magicHeader[1] ||
                receivedBytes[2] != _magicHeader[2]) {
              _activeSockets.remove(socket);
              socket.destroy();
              if (!handshakeCompleter.isCompleted) {
                handshakeCompleter.completeError(
                  const ProximityPairingException('Cabeçalho de protocolo inválido.'),
                );
              }
              return;
            }

            peerPayload = Uint8List.fromList(receivedBytes.sublist(3, 148));
            final nameLen = receivedBytes[148];
            if (receivedBytes.length < 149 + nameLen) return;

            peerNickname = utf8.decode(
              receivedBytes.sublist(149, 149 + nameLen),
              allowMalformed: true,
            );

            final remainingBytes = receivedBytes.sublist(149 + nameLen);
            receivedBytes.clear();
            handshakeReceived = true;

            // Calcula o código SAS de 6 dígitos a partir do payload recebido
            final sasCode = await core.computeSasCode(peerPayload: peerPayload!);

            if (!handshakeCompleter.isCompleted) {
              handshakeCompleter.complete(
                ProximityPairingConfirmation(
                  peerName: peerNickname.isNotEmpty ? peerNickname : peer.name,
                  channel: peer.channel,
                  sasCode: sasCode,
                  whenCancelled: remoteCancelledCompleter.future,
                  confirm: () async {
                    if (isCancelled) {
                      throw const ProximityPairingException('O pareamento foi cancelado.');
                    }
                    // Envia confirmação (ACK) para o receptor
                    try {
                      socket.add([_cmdConfirm]);
                      await socket.flush();
                    } catch (e) {
                      throw const ProximityPairingException(
                        'Falha de comunicação ao confirmar pareamento.',
                      );
                    }

                    // Se o outro lado ainda não confirmou, aguarda a confirmação mútua
                    if (!remoteConfirmed) {
                      await Future.any([
                        remoteConfirmCompleter.future,
                        remoteCancelledCompleter.future.then((_) {
                          throw const ProximityPairingException(
                            'O outro dispositivo cancelou ou recusou o pareamento.',
                          );
                        }),
                      ]).timeout(
                        const Duration(seconds: 45),
                        onTimeout: () {
                          throw const ProximityPairingException(
                            'Tempo esgotado aguardando confirmação do outro dispositivo.',
                          );
                        },
                      );
                    }

                    // Ambos confirmaram! Salva no banco de dados local
                    final contact = await core.pairFromQr(
                      payload: peerPayload!,
                      nickname: peerNickname.isNotEmpty ? peerNickname : peer.name,
                    );

                    isCompleted = true;
                    _activeSockets.remove(socket);
                    try {
                      await socket.flush();
                      await socket.close();
                    } catch (_) {}

                    return contact;
                  },
                  cancel: () {
                    if (!isCompleted && !isCancelled) {
                      isCancelled = true;
                      try {
                        socket.add([_cmdCancel]);
                        socket.flush().ignore();
                      } catch (_) {}
                      _activeSockets.remove(socket);
                      socket.destroy();
                    }
                  },
                ),
              );
            }

            // Processa bytes subsequentes (ex: confirmação ou cancelamento)
            for (final byte in remainingBytes) {
              _processControlByte(
                byte,
                onConfirm: () {
                  remoteConfirmed = true;
                  if (!remoteConfirmCompleter.isCompleted) {
                    remoteConfirmCompleter.complete();
                  }
                },
                onCancel: () {
                  isCancelled = true;
                  if (!remoteCancelledCompleter.isCompleted) {
                    remoteCancelledCompleter.complete();
                  }
                },
              );
            }
          } else {
            // Handshake já concluído; processa bytes de controle
            for (final byte in chunk) {
              _processControlByte(
                byte,
                onConfirm: () {
                  remoteConfirmed = true;
                  if (!remoteConfirmCompleter.isCompleted) {
                    remoteConfirmCompleter.complete();
                  }
                },
                onCancel: () {
                  isCancelled = true;
                  if (!remoteCancelledCompleter.isCompleted) {
                    remoteCancelledCompleter.complete();
                  }
                },
              );
            }
          }
        } catch (e) {
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.completeError(e);
          }
        }
      },
      onError: (err) {
        _activeSockets.remove(socket);
        if (!handshakeCompleter.isCompleted) {
          handshakeCompleter.completeError(err);
        }
        if (!remoteCancelledCompleter.isCompleted) {
          remoteCancelledCompleter.complete();
        }
      },
      onDone: () {
        _activeSockets.remove(socket);
        if (!isCompleted && !isCancelled) {
          if (!remoteCancelledCompleter.isCompleted) {
            remoteCancelledCompleter.complete();
          }
          if (!handshakeCompleter.isCompleted) {
            handshakeCompleter.completeError(
              const ProximityPairingException('Conexão encerrada antes da troca de chaves.'),
            );
          }
        }
      },
    );

    return handshakeCompleter.future;
  }

  void _handleIncomingConnection(Socket socket) {
    _activeSockets.add(socket);

    final remoteConfirmCompleter = Completer<void>();
    final remoteCancelledCompleter = Completer<void>();

    bool remoteConfirmed = false;
    bool isCompleted = false;
    bool isCancelled = false;

    final receivedBytes = <int>[];
    bool handshakeReceived = false;
    Uint8List? peerPayload;
    String peerNickname = '';

    socket.listen(
      (chunk) async {
        try {
          if (!handshakeReceived) {
            receivedBytes.addAll(chunk);
            if (receivedBytes.length < 149) return;

            if (receivedBytes[0] != _magicHeader[0] ||
                receivedBytes[1] != _magicHeader[1] ||
                receivedBytes[2] != _magicHeader[2]) {
              _activeSockets.remove(socket);
              socket.destroy();
              return;
            }

            peerPayload = Uint8List.fromList(receivedBytes.sublist(3, 148));
            final nameLen = receivedBytes[148];
            if (receivedBytes.length < 149 + nameLen) return;

            peerNickname = utf8.decode(
              receivedBytes.sublist(149, 149 + nameLen),
              allowMalformed: true,
            );

            final remainingBytes = receivedBytes.sublist(149 + nameLen);
            receivedBytes.clear();
            handshakeReceived = true;

            // 1. Responde IMEDIATAMENTE com nosso próprio Handshake Packet para
            // que o solicitante também possa computar o código SAS ao mesmo tempo!
            final myPayload = await core.myQrPayload();
            socket.add(_buildHandshakePacket(myPayload, _myName));
            await socket.flush();

            // 2. Computa o código SAS de 6 dígitos
            final sasCode = await core.computeSasCode(peerPayload: peerPayload!);

            // 3. Notifica a interface sobre a solicitação de pareamento recebida
            if (!_incomingRequestController.isClosed) {
              _incomingRequestController.add(
                IncomingProximityPairingRequest(
                  peerName: peerNickname.isNotEmpty ? peerNickname : 'Dispositivo Próximo',
                  channel: _myChannel,
                  sasCode: sasCode,
                  whenCancelled: remoteCancelledCompleter.future,
                  accept: () async {
                    if (isCancelled) {
                      throw const ProximityPairingException('O pareamento foi cancelado.');
                    }
                    // Envia confirmação (ACK) para o solicitante
                    try {
                      socket.add([_cmdConfirm]);
                      await socket.flush();
                    } catch (e) {
                      throw const ProximityPairingException(
                        'Falha de comunicação ao confirmar pareamento.',
                      );
                    }

                    // Se o outro lado ainda não confirmou, aguarda a confirmação mútua
                    if (!remoteConfirmed) {
                      await Future.any([
                        remoteConfirmCompleter.future,
                        remoteCancelledCompleter.future.then((_) {
                          throw const ProximityPairingException(
                            'O outro dispositivo cancelou ou encerrou o pareamento.',
                          );
                        }),
                      ]).timeout(
                        const Duration(seconds: 45),
                        onTimeout: () {
                          throw const ProximityPairingException(
                            'Tempo esgotado aguardando confirmação do outro dispositivo.',
                          );
                        },
                      );
                    }

                    // Ambos confirmaram! Salva o contato
                    final contact = await core.pairFromQr(
                      payload: peerPayload!,
                      nickname: peerNickname.isNotEmpty ? peerNickname : null,
                    );

                    isCompleted = true;
                    _activeSockets.remove(socket);
                    try {
                      await socket.flush();
                      await socket.close();
                    } catch (_) {}

                    return contact;
                  },
                  reject: () {
                    if (!isCompleted && !isCancelled) {
                      isCancelled = true;
                      try {
                        socket.add([_cmdCancel]);
                        socket.flush().ignore();
                      } catch (_) {}
                      _activeSockets.remove(socket);
                      socket.destroy();
                    }
                  },
                ),
              );
            }

            // Processa bytes subsequentes recebidos
            for (final byte in remainingBytes) {
              _processControlByte(
                byte,
                onConfirm: () {
                  remoteConfirmed = true;
                  if (!remoteConfirmCompleter.isCompleted) {
                    remoteConfirmCompleter.complete();
                  }
                },
                onCancel: () {
                  isCancelled = true;
                  if (!remoteCancelledCompleter.isCompleted) {
                    remoteCancelledCompleter.complete();
                  }
                },
              );
            }
          } else {
            // Handshake já concluído; processa bytes de controle
            for (final byte in chunk) {
              _processControlByte(
                byte,
                onConfirm: () {
                  remoteConfirmed = true;
                  if (!remoteConfirmCompleter.isCompleted) {
                    remoteConfirmCompleter.complete();
                  }
                },
                onCancel: () {
                  isCancelled = true;
                  if (!remoteCancelledCompleter.isCompleted) {
                    remoteCancelledCompleter.complete();
                  }
                },
              );
            }
          }
        } catch (_) {
          _activeSockets.remove(socket);
          socket.destroy();
        }
      },
      onError: (_) {
        _activeSockets.remove(socket);
        if (!remoteCancelledCompleter.isCompleted) {
          remoteCancelledCompleter.complete();
        }
      },
      onDone: () {
        _activeSockets.remove(socket);
        if (!isCompleted && !isCancelled) {
          if (!remoteCancelledCompleter.isCompleted) {
            remoteCancelledCompleter.complete();
          }
        }
      },
    );
  }

  void _processControlByte(
    int byte, {
    required VoidCallback onConfirm,
    required VoidCallback onCancel,
  }) {
    if (byte == _cmdConfirm) {
      onConfirm();
    } else if (byte == _cmdCancel) {
      onCancel();
    }
  }

  void dispose() {
    stop();
    _peersController.close();
    _incomingRequestController.close();
  }
}
