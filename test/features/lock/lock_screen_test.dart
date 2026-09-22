import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';

class _FakeCore implements Core {
  @override
  Future<void> unlock() async {}

  @override
  Future<int> sweepExpiredMessages() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalAuthentication implements LocalAuthentication {
  _FakeLocalAuthentication({this.shouldSucceed = true});

  bool shouldSucceed;
  int authCalls = 0;

  @override
  Future<bool> get canCheckBiometrics async => true;

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic>? authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authCalls++;
    return shouldSucceed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('LockScreen attempts unlock on display and shows error message on failure', (
    WidgetTester tester,
  ) async {
    final localAuth = _FakeLocalAuthentication(shouldSucceed: false);
    final controller = LockController(
      core: _FakeCore(),
      appDirPath: '/tmp/viska_test',
      localAuth: localAuth,
    );

    await tester.pumpWidget(
      MaterialApp(home: LockScreen(controller: controller)),
    );
    // Permite que o postFrameCallback execute
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Viska Bloqueado'), findsOneWidget);
    expect(find.text('Falha na autenticação ou cofre indisponível.'), findsOneWidget);
    expect(localAuth.authCalls, 1);

    // Agora permite sucesso e toca em Desbloquear
    localAuth.shouldSucceed = true;
    await tester.tap(find.text('Desbloquear'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(localAuth.authCalls, 2);
    expect(find.text('Falha na autenticação ou cofre indisponível.'), findsNothing);

    controller.dispose();
  });
}
