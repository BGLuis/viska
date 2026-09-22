import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../discovery/beacon_id.dart';

/// Canal lógico multiplexado sobre uma única conexão TCP — Fase 6, F1,
/// decisão de implementação flagged #1/#2 (não normativa em
/// `docs/protocol.md`): `wire::framing` não carrega identificador de canal,
/// então cada conexão TCP recebe um preâmbulo de 17 bytes antes do primeiro
/// quadro, usado só para o `LanListener` rotear a conexão ao par certo.
enum LanChannel {
  control(0x00),
  file(0x01);

  const LanChannel(this.wireValue);

  final int wireValue;

  static LanChannel? fromWireValue(int value) =>
      switch (value) { 0x00 => LanChannel.control, 0x01 => LanChannel.file, _ => null };
}

const int _deviceIdLen = 16;

/// Preâmbulo de uma conexão TCP: `device_id` (16 bytes) de quem discou +
/// canal (1 byte) — dado já público (trocado no QR), não segredo.
Uint8List encodePreamble({required Uint8List deviceId, required LanChannel channel}) {
  if (deviceId.length != _deviceIdLen) {
    throw ArgumentError.value(deviceId.length, 'deviceId.length', 'esperado 16 bytes');
  }
  final out = Uint8List(_deviceIdLen + 1);
  out.setRange(0, _deviceIdLen, deviceId);
  out[_deviceIdLen] = channel.wireValue;
  return out;
}

/// Uma conexão TCP já identificada por `(deviceId, channel)` — o que
/// [LanListener] entrega ao lado passivo, e o que o lado ativo constrói ao
/// discar. `incoming` já exclui o preâmbulo, se houver: pronto para
/// `wire::framing`.
class LanConnection {
  LanConnection({required Socket socket, required this.incoming}) : _socket = socket;

  final Socket _socket;
  final Stream<Uint8List> incoming;

  void add(List<int> bytes) => _socket.add(bytes);

  void destroy() => _socket.destroy();

  Future<void> close() => _socket.close();
}

/// `device_id` (hex) + canal — chave de quem está esperando uma conexão
/// entrante específica.
String _waitKey(Uint8List deviceId, LanChannel channel) =>
    '${toHexInstanceName(deviceId)}:${channel.wireValue}';

/// Um único `ServerSocket` por processo, compartilhado por todos os
/// contatos — decisão de implementação flagged #3: evita abrir uma porta
/// por contato. `LanTransport.connect()` (F1) registra uma espera por
/// `(deviceId, channel)` antes de anunciar/discar; o `accept()` lê o
/// preâmbulo de cada conexão entrante e a entrega a quem está esperando.
class LanListener {
  /// Instância compartilhada por todo o processo — usada por
  /// `transport_candidates.dart` (Fase 6, F3) para que todo `LanTransport`
  /// construído para qualquer contato escute na mesma porta.
  static final LanListener shared = LanListener();

  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSub;
  final Map<String, Completer<LanConnection>> _waiting = {};

  /// Porta em que o listener está escutando — liga sob demanda na primeira
  /// chamada, e permanece ligado pelo resto da vida do processo.
  Future<int> ensureListening() async {
    final existing = _server;
    if (existing != null) return existing.port;

    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _acceptSub = server.listen(_acceptConnection, onError: (Object _) {});
    return server.port;
  }

  /// Espera a próxima conexão entrante para `(deviceId, channel)` — o lado
  /// ativo desse par já deve estar discando com o preâmbulo correspondente.
  Future<LanConnection> waitForConnection({
    required Uint8List deviceId,
    required LanChannel channel,
  }) {
    final key = _waitKey(deviceId, channel);
    final completer = _waiting.putIfAbsent(key, () => Completer<LanConnection>());
    return completer.future;
  }

  /// Desiste de uma espera pendente — ex.: outro candidato de transporte já
  /// conectou por outro caminho, e a próxima conexão TCP que chegar por
  /// engano (ou atrasada) deve ser só descartada, não represada para
  /// sempre.
  void cancelWait({required Uint8List deviceId, required LanChannel channel}) {
    _waiting.remove(_waitKey(deviceId, channel));
  }

  Future<void> close() async {
    await _acceptSub?.cancel();
    await _server?.close();
    _server = null;
    _acceptSub = null;
    _waiting.clear();
  }

  void _acceptConnection(Socket socket) {
    unawaited(() async {
      try {
        await _routeConnection(socket);
      } catch (_) {
        try {
          socket.destroy();
        } catch (_) {}
      }
    }());
  }

  Future<void> _routeConnection(Socket socket) async {
    try {
      final peeled = await _peelPreamble(socket);
      if (peeled == null) {
        socket.destroy();
        return;
      }
      final key = _waitKey(peeled.deviceId, peeled.channel);
      final completer = _waiting.remove(key);
      if (completer == null) {
        // Ninguém está esperando essa conexão agora (contato desconhecido, ou
        // já resolvida por outro caminho) — descarta.
        socket.destroy();
        return;
      }
      completer.complete(LanConnection(socket: socket, incoming: peeled.rest));
    } catch (_) {
      try {
        socket.destroy();
      } catch (_) {}
    }
  }
}

class _PeeledPreamble {
  _PeeledPreamble({required this.deviceId, required this.channel, required this.rest});

  final Uint8List deviceId;
  final LanChannel channel;
  final Stream<Uint8List> rest;
}

/// Consome do socket exatamente os primeiros 17 bytes (o preâmbulo) e
/// devolve, junto com eles, um stream equivalente ao restante da conexão —
/// sem perder nenhum byte que tenha chegado no mesmo pacote TCP do
/// preâmbulo. `null` se a conexão fechou antes de completar o preâmbulo.
Future<_PeeledPreamble?> _peelPreamble(Socket socket) async {
  const preambleLen = _deviceIdLen + 1;
  final controller = StreamController<Uint8List>();
  final buffer = BytesBuilder(copy: false);
  var completer = Completer<Uint8List?>();

  final sub = socket.listen(
    (chunk) {
      if (!completer.isCompleted) {
        buffer.add(chunk);
        if (buffer.length >= preambleLen) {
          final all = buffer.toBytes();
          final preamble = all.sublist(0, preambleLen);
          final leftover = all.sublist(preambleLen);
          completer.complete(preamble);
          if (leftover.isNotEmpty) controller.add(leftover);
        }
        return;
      }
      controller.add(chunk);
    },
    onError: (Object e, StackTrace st) {
      if (!completer.isCompleted) completer.complete(null);
      controller.addError(e, st);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
      unawaited(controller.close());
    },
  );
  controller.onCancel = () => sub.cancel();

  final preamble = await completer.future;
  if (preamble == null) {
    await sub.cancel();
    return null;
  }

  final channel = LanChannel.fromWireValue(preamble[_deviceIdLen]);
  if (channel == null) {
    await sub.cancel();
    return null;
  }

  return _PeeledPreamble(
    deviceId: preamble.sublist(0, _deviceIdLen),
    channel: channel,
    rest: controller.stream,
  );
}
