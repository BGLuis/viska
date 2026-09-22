import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'proxy_config.dart';

/// Cliente e túnel SOCKS5 em conformidade com RFC 1928 e RFC 1929.
///
/// Permite conectar-se a nós Tor locais (como Orbot em 127.0.0.1:9050) com
/// resolução remota de DNS (ATYP 0x03) para evitar qualquer vazamento de IP/DNS.
class Socks5Tunnel {
  Socks5Tunnel._();

  /// Estabelece uma conexão via proxy SOCKS5 até o alvo (`targetHost`:`targetPort`).
  static Future<Socket> connect({
    required ProxyConfig config,
    required String targetHost,
    required int targetPort,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await Socket.connect(config.host, config.port, timeout: timeout);

    try {
      final reader = _SocketByteReader(socket);

      // 1. Saudação SOCKS5 (RFC 1928 §3)
      final hasAuth = config.username != null &&
          config.username!.isNotEmpty &&
          config.password != null &&
          config.password!.isNotEmpty;

      if (hasAuth) {
        // Métodos suportados: 0x00 (sem auth) e 0x02 (usuário/senha)
        socket.add(Uint8List.fromList([0x05, 0x02, 0x00, 0x02]));
      } else {
        // Método: 0x00 (sem autenticação)
        socket.add(Uint8List.fromList([0x05, 0x01, 0x00]));
      }
      await socket.flush();

      final greetingResp = await reader.readBytes(2, timeout);
      if (greetingResp[0] != 0x05) {
        throw const SocketException('Versão SOCKS inválida recebida do proxy');
      }

      final chosenMethod = greetingResp[1];
      if (chosenMethod == 0xFF) {
        throw const SocketException('Proxy SOCKS5 rejeitou métodos de autenticação');
      }

      // 2. Subnegociação de autenticação usuário/senha se solicitada (RFC 1929)
      if (chosenMethod == 0x02) {
        final uBytes = utf8.encode(config.username ?? '');
        final pBytes = utf8.encode(config.password ?? '');
        final authPacket = Uint8List.fromList([
          0x01,
          uBytes.length,
          ...uBytes,
          pBytes.length,
          ...pBytes,
        ]);
        socket.add(authPacket);
        await socket.flush();

        final authResp = await reader.readBytes(2, timeout);
        if (authResp[1] != 0x00) {
          throw const SocketException('Autenticação de usuário/senha no SOCKS5 falhou');
        }
      }

      // 3. Solicitação de conexão CONNECT (RFC 1928 §4)
      final requestBytes = <int>[0x05, 0x01, 0x00];

      // Se for IPv4 numérico, usa ATYP 0x01, caso contrário ATYP 0x03 (Domain Name)
      final ip = InternetAddress.tryParse(targetHost);
      if (ip != null && ip.type == InternetAddressType.IPv4) {
        requestBytes.add(0x01);
        requestBytes.addAll(ip.rawAddress);
      } else {
        // ATYP 0x03: Evita vazamento de DNS no Tor resolvendo no nó de saída
        final domainBytes = utf8.encode(targetHost);
        requestBytes.add(0x03);
        requestBytes.add(domainBytes.length);
        requestBytes.addAll(domainBytes);
      }

      // Porta destino em 2 bytes big-endian
      requestBytes.add((targetPort >> 8) & 0xFF);
      requestBytes.add(targetPort & 0xFF);

      socket.add(Uint8List.fromList(requestBytes));
      await socket.flush();

      // 4. Leitura da resposta do proxy (RFC 1928 §6)
      final head = await reader.readBytes(4, timeout);
      final rep = head[1];
      if (rep != 0x00) {
        throw SocketException('Falha na conexão SOCKS5 com código de erro: $rep');
      }

      final atyp = head[3];
      int addrLen;
      if (atyp == 0x01) {
        addrLen = 4; // IPv4
      } else if (atyp == 0x03) {
        final lenByte = await reader.readBytes(1, timeout);
        addrLen = lenByte[0];
      } else if (atyp == 0x04) {
        addrLen = 16; // IPv6
      } else {
        throw const SocketException('Tipo de endereço SOCKS5 desconhecido na resposta');
      }

      // Descarta endereço vinculado e porta vinculada (2 bytes)
      await reader.readBytes(addrLen + 2, timeout);

      // Desvincula o leitor interno e retorna o socket transparente
      return reader.detach();
    } catch (e) {
      socket.destroy();
      rethrow;
    }
  }
}

/// Servidor intermediário local (loopback) para conectar clientes que não suportam
/// SOCKS5 nativamente (como `MqttServerClient`) através de um túnel transparente.
class Socks5LocalForwarder {
  Socks5LocalForwarder._(this._server, this._config, this._targetHost, this._targetPort) {
    _server.listen(_handleIncomingClient);
  }

  final ServerSocket _server;
  final ProxyConfig _config;
  final String _targetHost;
  final int _targetPort;
  final List<Socket> _activeSockets = [];

  int get port => _server.port;

  /// Inicia o forwarder local em uma porta efêmera de loopback.
  static Future<Socks5LocalForwarder> start({
    required ProxyConfig config,
    required String targetHost,
    required int targetPort,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return Socks5LocalForwarder._(server, config, targetHost, targetPort);
  }

  void _handleIncomingClient(Socket clientSocket) async {
    _activeSockets.add(clientSocket);
    try {
      final proxySocket = await Socks5Tunnel.connect(
        config: _config,
        targetHost: _targetHost,
        targetPort: _targetPort,
      );
      _activeSockets.add(proxySocket);

      // Ponte bidirecional transparente
      clientSocket.listen(
        (data) => proxySocket.add(data),
        onError: (_) => _cleanup(clientSocket, proxySocket),
        onDone: () => _cleanup(clientSocket, proxySocket),
        cancelOnError: true,
      );

      proxySocket.listen(
        (data) => clientSocket.add(data),
        onError: (_) => _cleanup(clientSocket, proxySocket),
        onDone: () => _cleanup(clientSocket, proxySocket),
        cancelOnError: true,
      );
    } catch (_) {
      clientSocket.destroy();
      _activeSockets.remove(clientSocket);
    }
  }

  void _cleanup(Socket a, Socket b) {
    a.destroy();
    b.destroy();
    _activeSockets.remove(a);
    _activeSockets.remove(b);
  }

  /// Fecha o servidor local e todos os sockets ativos.
  Future<void> close() async {
    final sockets = List<Socket>.of(_activeSockets);
    for (final s in sockets) {
      s.destroy();
    }
    _activeSockets.clear();
    await _server.close();
  }

  /// Alias para [close].
  Future<void> stop() => close();
}

/// Auxiliar para leitura de número exato de bytes de um socket antes do streaming.
class _SocketByteReader {
  _SocketByteReader(this._socket) {
    _streamController = StreamController<Uint8List>();
    _subscription = _socket.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        if (_completer != null && !_completer!.isCompleted) {
          _completer!.completeError(e, st);
        }
        _streamController.addError(e, st);
      },
      onDone: () {
        if (_completer != null && !_completer!.isCompleted) {
          _completer!.completeError(const SocketException('Conexão fechada'));
        }
        _streamController.close();
      },
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  late final StreamController<Uint8List> _streamController;
  final List<int> _buffer = [];
  Completer<Uint8List>? _completer;
  int _neededBytes = 0;
  bool _detached = false;

  void _onData(Uint8List chunk) {
    if (_detached) {
      _streamController.add(chunk);
      return;
    }

    _buffer.addAll(chunk);
    _check();
  }

  void _check() {
    if (_completer != null && _buffer.length >= _neededBytes) {
      final result = Uint8List.fromList(_buffer.sublist(0, _neededBytes));
      _buffer.removeRange(0, _neededBytes);
      final c = _completer;
      _completer = null;
      _neededBytes = 0;
      c?.complete(result);
    }
  }

  Future<Uint8List> readBytes(int count, Duration timeout) {
    if (_buffer.length >= count) {
      final result = Uint8List.fromList(_buffer.sublist(0, count));
      _buffer.removeRange(0, count);
      return Future.value(result);
    }

    _neededBytes = count;
    _completer = Completer<Uint8List>();
    return _completer!.future.timeout(timeout, onTimeout: () {
      _completer = null;
      throw const SocketException('Timeout durante handshake SOCKS5');
    });
  }

  Socket detach() {
    _detached = true;
    if (_buffer.isNotEmpty) {
      _streamController.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    return _ProxiedSocket(_socket, _streamController.stream, _subscription);
  }
}

/// Socket proxy transparente que expõe o stream após o handshake inicial.
class _ProxiedSocket extends Stream<Uint8List> implements Socket {
  _ProxiedSocket(this._rawSocket, this._incomingStream, this._subscription);

  final Socket _rawSocket;
  final Stream<Uint8List> _incomingStream;
  final StreamSubscription<Uint8List> _subscription;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incomingStream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(List<int> data) => _rawSocket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _rawSocket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _rawSocket.addStream(stream);

  @override
  Future<void> flush() => _rawSocket.flush();

  @override
  Future<void> close() {
    _subscription.cancel();
    return _rawSocket.close();
  }

  @override
  void destroy() {
    _subscription.cancel();
    _rawSocket.destroy();
  }

  @override
  Future<dynamic> get done => _rawSocket.done;

  @override
  InternetAddress get address => _rawSocket.address;

  @override
  InternetAddress get remoteAddress => _rawSocket.remoteAddress;

  @override
  int get port => _rawSocket.port;

  @override
  int get remotePort => _rawSocket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) => _rawSocket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _rawSocket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _rawSocket.setRawOption(option);

  @override
  void write(Object? object) => _rawSocket.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = ""]) =>
      _rawSocket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _rawSocket.writeCharCode(charCode);

  @override
  void writeln([Object? object = ""]) => _rawSocket.writeln(object);

  @override
  Encoding get encoding => _rawSocket.encoding;

  @override
  set encoding(Encoding value) => _rawSocket.encoding = value;
}
