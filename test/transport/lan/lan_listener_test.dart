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

  test('connection is routed to waiter for same device_id and channel', () async {
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

  test('control and file for same contact are independent connections', () async {
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

  test('bytes after preamble in same packet are not lost', () async {
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

  test('connection with no waiter is dropped', () async {
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

  test('cancelWait causes next matching connection to be dropped', () async {
    final port = await listener.ensureListening();
    final deviceId = _deviceId(0x2);

    final waitFuture = listener.waitForConnection(deviceId: deviceId, channel: LanChannel.control);

    // Registrar o expectLater ANTES de cancelWait: cancelWait completa o
    // Completer de forma síncrona, então o listener de erro precisa existir
    // antes da chamada para evitar StateError unhandled.
    final expectation = expectLater(waitFuture, throwsA(isA<StateError>()));
    listener.cancelWait(deviceId: deviceId, channel: LanChannel.control);

    // A conexão TCP que chega depois do cancelWait deve ser descartada pelo
    // listener (ninguém está esperando por ela).
    final socket = await _dial(port, deviceId: deviceId, channel: LanChannel.control);
    addTearDown(socket.destroy);
    await _expectClosedByPeer(socket);

    await expectation;
  });

  test('cancelWait completes the pending Future immediately without memory leak', () async {
    await listener.ensureListening();
    final deviceId = _deviceId(0x3);

    // Registrar a espera — sem discar nenhuma conexão.
    final waitFuture = listener.waitForConnection(
      deviceId: deviceId,
      channel: LanChannel.control,
    );

    // Registrar o expectLater ANTES de cancelWait pelo mesmo motivo do teste
    // anterior: cancelWait completa o Completer de forma síncrona.
    final expectation = expectLater(waitFuture, throwsA(isA<StateError>()));
    listener.cancelWait(deviceId: deviceId, channel: LanChannel.control);

    await expectation;
  });
}
