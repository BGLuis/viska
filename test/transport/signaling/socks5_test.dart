import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/signaling/proxy_config.dart';
import 'package:viska/src/transport/signaling/socks5_client.dart';

/// Servidor SOCKS5 mock em loopback para testes automatizados de handshake.
class _MockSocks5Server {
  _MockSocks5Server({this.requireAuth = false, this.expectedUser, this.expectedPass});

  final bool requireAuth;
  final String? expectedUser;
  final String? expectedPass;

  ServerSocket? _server;
  int get port => _server!.port;

  final connections = <Socket>[];

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleClient);
  }

  void _handleClient(Socket client) {
    connections.add(client);
    var state = 0; // 0: greeting, 1: auth, 2: connect

    client.listen((data) {
      if (state == 0) {
        // Handshake greeting: [0x05, nmethods, methods...]
        if (data.length >= 3 && data[0] == 0x05) {
          if (requireAuth) {
            client.add([0x05, 0x02]); // Username/password
            state = 1;
          } else {
            client.add([0x05, 0x00]); // No auth
            state = 2;
          }
        }
      } else if (state == 1) {
        // RFC 1929 Auth: [0x01, ulen, user..., plen, pass...]
        if (data.isNotEmpty && data[0] == 0x01) {
          final ulen = data[1];
          final user = String.fromCharCodes(data.sublist(2, 2 + ulen));
          final plen = data[2 + ulen];
          final pass = String.fromCharCodes(data.sublist(3 + ulen, 3 + ulen + plen));

          if (user == expectedUser && pass == expectedPass) {
            client.add([0x01, 0x00]); // Success
            state = 2;
          } else {
            client.add([0x01, 0x01]); // Failure
            client.destroy();
          }
        }
      } else if (state == 2) {
        // Connect request: [0x05, 0x01 (CONNECT), 0x00, atyp, ...]
        if (data.length >= 4 && data[0] == 0x05 && data[1] == 0x01) {
          // Reply success: [0x05, 0x00 (SUCCESS), 0x00, 0x01 (IPv4), 127, 0, 0, 1, port_hi, port_lo]
          client.add([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90]);
          state = 3; // Connected! Echo back any data
        }
      } else if (state == 3) {
        // Echo test payload
        client.add(data);
      }
    });
  }

  Future<void> stop() async {
    for (final c in connections) {
      c.destroy();
    }
    await _server?.close();
  }
}

void main() {
  group('SOCKS5 Client & Tunnel Tests', () {
    test('successfully handshakes with no authentication', () async {
      final mock = _MockSocks5Server(requireAuth: false);
      await mock.start();

      final config = ProxyConfig(
        enabled: true,
        host: '127.0.0.1',
        port: mock.port,
      );

      final socket = await Socks5Tunnel.connect(
        config: config,
        targetHost: '127.0.0.1',
        targetPort: 8080,
      );

      expect(socket, isNotNull);

      // Envia dados pelo túnel e recebe o eco
      final completer = Completer<Uint8List>();
      socket.listen((bytes) {
        if (!completer.isCompleted) completer.complete(bytes);
      });

      socket.add([1, 2, 3, 4]);
      final received = await completer.future.timeout(const Duration(seconds: 2));
      expect(received, [1, 2, 3, 4]);

      socket.destroy();
      await mock.stop();
    });

    test('successfully handshakes with RFC 1929 username and password', () async {
      final mock = _MockSocks5Server(
        requireAuth: true,
        expectedUser: 'viska-user',
        expectedPass: 'tor-secret',
      );
      await mock.start();

      final config = ProxyConfig(
        enabled: true,
        host: '127.0.0.1',
        port: mock.port,
        username: 'viska-user',
        password: 'tor-secret',
      );

      final socket = await Socks5Tunnel.connect(
        config: config,
        targetHost: 'broker.viska.network',
        targetPort: 1883,
      );

      expect(socket, isNotNull);

      socket.destroy();
      await mock.stop();
    });

    test('rejects connection when credentials are wrong', () async {
      final mock = _MockSocks5Server(
        requireAuth: true,
        expectedUser: 'viska-user',
        expectedPass: 'tor-secret',
      );
      await mock.start();

      final config = ProxyConfig(
        enabled: true,
        host: '127.0.0.1',
        port: mock.port,
        username: 'wrong-user',
        password: 'wrong-password',
      );

      expect(
        () => Socks5Tunnel.connect(
          config: config,
          targetHost: '127.0.0.1',
          targetPort: 1883,
        ),
        throwsA(isA<SocketException>()),
      );

      await mock.stop();
    });

    test('Socks5LocalForwarder bridges local port to remote via tunnel', () async {
      final mock = _MockSocks5Server(requireAuth: false);
      await mock.start();

      final config = ProxyConfig(
        enabled: true,
        host: '127.0.0.1',
        port: mock.port,
      );

      final forwarder = await Socks5LocalForwarder.start(
        config: config,
        targetHost: '127.0.0.1',
        targetPort: 1883,
      );

      expect(forwarder.port, greaterThan(0));

      // Conecta cliente local ao forwarder
      final clientSocket = await Socket.connect(InternetAddress.loopbackIPv4, forwarder.port);
      final completer = Completer<Uint8List>();
      clientSocket.listen((data) {
        if (!completer.isCompleted) completer.complete(data);
      });

      clientSocket.add([42, 43, 44]);
      final response = await completer.future.timeout(const Duration(seconds: 2));
      expect(response, [42, 43, 44]);

      clientSocket.destroy();
      await forwarder.stop();
      await mock.stop();
    });
  });
}
