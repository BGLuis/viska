import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:local_auth_platform_interface/types/auth_messages.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/rust/ffi/core.dart';

class _FakeCore implements Core {
  var lockCalls = 0;
  var unlockCalls = 0;
  var emergencyEraseCalls = 0;
  var sweepCalls = 0;
  var throwOnLock = false;
  var throwOnUnlock = false;

  @override
  Future<void> lock() async {
    lockCalls++;
    if (throwOnLock) throw StateError('erro ao travar o cofre');
  }

  @override
  Future<void> unlock() async {
    unlockCalls++;
    if (throwOnUnlock) throw StateError('erro ao destrancar o cofre');
  }

  @override
  Future<void> emergencyErase() async {
    emergencyEraseCalls++;
  }

  @override
  Future<int> sweepExpiredMessages() async {
    sweepCalls++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocalAuthentication implements LocalAuthentication {
  var canCheckBiometricsValue = true;
  var isDeviceSupportedValue = true;
  var authenticateResult = true;
  var throwPlatformException = false;
  var authenticateCalls = 0;

  @override
  Future<bool> get canCheckBiometrics async => canCheckBiometricsValue;

  @override
  Future<bool> isDeviceSupported() async => isDeviceSupportedValue;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<AuthMessages>? authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authenticateCalls++;
    if (throwPlatformException) {
      throw PlatformException(code: 'AuthFailed', message: 'Biometria falhou');
    }
    return authenticateResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCore core;
  late _FakeLocalAuthentication localAuth;

  setUp(() {
    core = _FakeCore();
    localAuth = _FakeLocalAuthentication();
  });

  group('LockController state and transitions', () {
    test('starts in unlocked state', () {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      expect(controller.isLocked.value, isFalse);
    });

    test('lock calls core.lock and marks isLocked as true', () async {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();

      expect(core.lockCalls, 1);
      expect(controller.isLocked.value, isTrue);
    });

    test('calling lock when already locked is a no-op', () async {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();
      await controller.lock();

      expect(core.lockCalls, 1);
      expect(controller.isLocked.value, isTrue);
    });

    test('lock sets isLocked to true even if core.lock throws', () async {
      core.throwOnLock = true;
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();

      expect(core.lockCalls, 1);
      expect(controller.isLocked.value, isTrue);
    });
  });

  group('Inactivity timer', () {
    test('inactivity timeout automatically triggers lock', () {
      fakeAsync((async) {
        final controller = LockController(
          core: core,
          appDirPath: '/tmp/viska_test',
          localAuth: localAuth,
          autoLockTimeout: const Duration(seconds: 60),
        );

        async.elapse(const Duration(seconds: 59));
        expect(controller.isLocked.value, isFalse);

        async.elapse(const Duration(seconds: 2));
        expect(controller.isLocked.value, isTrue);
        expect(core.lockCalls, 1);

        controller.dispose();
      });
    });

    test('onUserInteraction postpones inactivity lock', () {
      fakeAsync((async) {
        final controller = LockController(
          core: core,
          appDirPath: '/tmp/viska_test',
          localAuth: localAuth,
          autoLockTimeout: const Duration(seconds: 60),
        );

        // Usuário interage aos 40s
        async.elapse(const Duration(seconds: 40));
        controller.onUserInteraction();

        // Passam mais 40s (total 80s desde o início, mas 40s da última interação)
        async.elapse(const Duration(seconds: 40));
        expect(controller.isLocked.value, isFalse);

        // Mais 21s completam os 61s da última interação -> bloqueia
        async.elapse(const Duration(seconds: 21));
        expect(controller.isLocked.value, isTrue);

        controller.dispose();
      });
    });

    test('onUserInteraction does nothing when already locked', () {
      fakeAsync((async) {
        final controller = LockController(
          core: core,
          appDirPath: '/tmp/viska_test',
          localAuth: localAuth,
          autoLockTimeout: const Duration(seconds: 60),
        );

        async.elapse(const Duration(seconds: 65));
        expect(controller.isLocked.value, isTrue);

        controller.onUserInteraction();
        expect(controller.isLocked.value, isTrue);

        controller.dispose();
      });
    });
  });

  group('Unlock behaviour', () {
    test('unlock with successful biometric auth and core.unlock succeeds and sweeps', () async {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();
      expect(controller.isLocked.value, isTrue);

      final success = await controller.unlock();

      expect(success, isTrue);
      expect(controller.isLocked.value, isFalse);
      expect(localAuth.authenticateCalls, 1);
      expect(core.unlockCalls, 1);
      expect(core.sweepCalls, 1);
    });

    test('unlock returns false and stays locked when biometric auth is rejected', () async {
      localAuth.authenticateResult = false;
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();
      final success = await controller.unlock();

      expect(success, isFalse);
      expect(controller.isLocked.value, isTrue);
      expect(core.unlockCalls, 0);
    });

    test('unlock returns false and stays locked on PlatformException', () async {
      localAuth.throwPlatformException = true;
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();
      final success = await controller.unlock();

      expect(success, isFalse);
      expect(controller.isLocked.value, isTrue);
      expect(core.unlockCalls, 0);
    });

    test('unlock returns false and stays locked when core.unlock throws', () async {
      core.throwOnUnlock = true;
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();
      final success = await controller.unlock();

      expect(success, isFalse);
      expect(controller.isLocked.value, isTrue);
      expect(core.unlockCalls, 1);
    });
  });

  group('Emergency erase', () {
    test('emergencyErase calls core.emergencyErase and locks app', () async {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.emergencyErase();

      expect(core.emergencyEraseCalls, 1);
      expect(controller.isLocked.value, isTrue);
    });
  });

  group('App lifecycle events', () {
    test('paused locks immediately when autoLockOnBackground is true', () async {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
        autoLockOnBackground: true,
      );
      addTearDown(controller.dispose);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();

      expect(controller.isLocked.value, isTrue);
      expect(core.lockCalls, 1);
    });

    test('paused does not lock when autoLockOnBackground is false', () {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
        autoLockOnBackground: false,
      );
      addTearDown(controller.dispose);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(controller.isLocked.value, isFalse);
      expect(core.lockCalls, 0);
    });

    test('resumed sweeps expired messages when app is unlocked', () {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(core.sweepCalls, 1);
    });

    test('resumed does not sweep when app is locked', () async {
      final controller = LockController(
        core: core,
        appDirPath: '/tmp/viska_test',
        localAuth: localAuth,
      );
      addTearDown(controller.dispose);

      await controller.lock();
      final sweepsBefore = core.sweepCalls;

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(core.sweepCalls, sweepsBefore);
    });
  });
}
