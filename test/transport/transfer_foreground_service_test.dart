import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/transfer_foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;
  late Object? Function(MethodCall call) handler;
  const channel = MethodChannel('viska/transfer_service');

  TransferForegroundService makeService() => TransferForegroundService(channel: channel, enabled: true);

  setUp(() {
    calls = [];
    handler = (call) {
      calls.add(call.method);
      return null;
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => handler(call));
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('overlapping leases start the service once and stop it after the last one', () async {
    final service = makeService();

    final picker = await service.acquire();
    final transfer = await service.acquire();
    expect(calls, ['start']);

    await picker.release();
    expect(calls, ['start'], reason: 'a transferência ainda precisa do serviço');

    await transfer.release();
    expect(calls, ['start', 'stop']);
  });

  test('releasing the same lease twice does not stop a service another lease still needs', () async {
    final service = makeService();
    final first = await service.acquire();
    final second = await service.acquire();

    await first.release();
    await first.release();

    expect(calls, ['start']);
    await second.release();
    expect(calls, ['start', 'stop']);
  });

  test('platform failure does not break the transfer', () async {
    handler = (call) => throw PlatformException(code: 'not_allowed');
    final service = makeService();

    final lease = await service.acquire();
    await lease.release();
  });

  test('missing platform channel is ignored', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final service = makeService();

    final lease = await service.acquire();
    await lease.release();
  });

  test('disabled service never touches the channel', () async {
    final service = TransferForegroundService(channel: channel, enabled: false);

    final lease = await service.acquire();
    await lease.release();

    expect(calls, isEmpty);
  });
}
