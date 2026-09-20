import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/lan/lan_listener.dart';

Uint8List _deviceId(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

Future<Socket> _dial(int port, {required Uint8List deviceId, required LanChannel channel}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.add(encodePreamble(deviceId: deviceId, channel: channel));
  await socket.flush();
  return socket;
}

Future<void> _expectClosedByPeer(Socket socket) async {
  final closed = Completer<void>();
  socket.listen(
    (_) {},
    onDone: () => closed.complete(),
    onError: (Object _) {
      if (!closed.isCompleted) closed.complete();
    },
    cancelOnError: true,
  );
  await closed.future.timeout(const Duration(seconds: 5));
}

void main() {
  late LanListener listener;

  setUp(() {
    listener = LanListener();
  });

  tearDown(() async {
    await listener.close();
  });

  test('conexao_e_roteada_para_quem_espera_o_mesmo_device_id_e_canal', () async {
    final port = await listener.ensureListening();
    final deviceId = _deviceId(0x42);

    final waitFuture = listener.waitForConnection(deviceId: deviceId, channel: LanChannel.control);
    final dialSocket = await _dial(port, deviceId: deviceId, channel: LanChannel.control);
    addTearDown(dialSocket.destroy);

    final connection = await waitFuture.timeout(const Duration(seconds: 5));

    dialSocket.add(Uint8List.fromList([1, 2, 3]));
    await dialSocket.flush();

    final received = await connection.incoming.first.timeout(const Duration(seconds: 5));
    expect(received, [1, 2, 3]);
  });

  test('control_e_file_do_mesmo_contato_sao_conexoes_independentes', () async {
    final port = await listener.ensureListening();
    final deviceId = _deviceId(0x7);

    final waitControl = listener.waitForConnection(deviceId: deviceId, channel: LanChannel.control);
    final waitFile = listener.waitForConnection(deviceId: deviceId, channel: LanChannel.file);

    final controlSocket = await _dial(port, deviceId: deviceId, channel: LanChannel.control);
    addTearDown(controlSocket.destroy);
    final fileSocket = await _dial(port, deviceId: deviceId, channel: LanChannel.file);
    addTearDown(fileSocket.destroy);

    final control = await waitControl.timeout(const Duration(seconds: 5));
    final file = await waitFile.timeout(const Duration(seconds: 5));

    controlSocket.add(Uint8List.fromList([0xC]));
    await controlSocket.flush();
    fileSocket.add(Uint8List.fromList([0xF]));
    await fileSocket.flush();

    expect(await control.incoming.first.timeout(const Duration(seconds: 5)), [0xC]);
    expect(await file.incoming.first.timeout(const Duration(seconds: 5)), [0xF]);
  });

  test('bytes_apos_o_preambulo_no_mesmo_pacote_nao_sao_perdidos', () async {
    final port = await listener.ensureListening();
    final deviceId = _deviceId(0x9);

    final waitFuture = listener.waitForConnection(deviceId: deviceId, channel: LanChannel.control);

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(socket.destroy);
    // Preâmbulo e o primeiro quadro no mesmo `add()` — simula o SO
    // entregando os dois num único pacote TCP.
    final preamble = encodePreamble(deviceId: deviceId, channel: LanChannel.control);
    final frameStart = Uint8List.fromList([0xAA, 0xBB]);
    socket.add(Uint8List.fromList([...preamble, ...frameStart]));
    await socket.flush();

    final connection = await waitFuture.timeout(const Duration(seconds: 5));
    final received = await connection.incoming.first.timeout(const Duration(seconds: 5));

    expect(received, frameStart);
  });

  test('conexao_sem_ninguem_esperando_e_descartada', () async {
    final port = await listener.ensureListening();
    final deviceId = _deviceId(0x1);

    final socket = await _dial(port, deviceId: deviceId, channel: LanChannel.control);
    addTearDown(socket.destroy);

    // Sem `waitForConnection` correspondente: a conexão deve ser fechada
    // pelo listener em vez de ficar pendurada — aceita tanto o fechamento
    // limpo (`onDone`) quanto um reset percebido como erro pelo cliente,
    // já que `Socket.destroy()` não garante qual dos dois o SO entrega.
    await _expectClosedByPeer(socket);
  });

  test('cancelWait_faz_a_proxima_conexao_correspondente_ser_descartada', () async {
    final port = await listener.ensureListening();
    final deviceId = _deviceId(0x2);

    final waitFuture = listener.waitForConnection(deviceId: deviceId, channel: LanChannel.control);
    listener.cancelWait(deviceId: deviceId, channel: LanChannel.control);

    final socket = await _dial(port, deviceId: deviceId, channel: LanChannel.control);
    addTearDown(socket.destroy);
    await _expectClosedByPeer(socket);

    // O `Future` da espera cancelada nunca completa — não há mais ninguém
    // interessado nele.
    expect(waitFuture.timeout(const Duration(milliseconds: 200)), throwsA(isA<TimeoutException>()));
  });
}
