import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';

class _FakeLocalAuthentication implements LocalAuthentication {
  _FakeLocalAuthentication({this.shouldSucceed = false});

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

class _FakeCore implements Core {
  var lockCalls = 0;
  var unlockCalls = 0;
  var emergencyEraseCalls = 0;

  @override
  Future<void> lock() async {
    lockCalls++;
  }

  @override
  Future<void> unlock() async {
    unlockCalls++;
  }

  @override
  Future<void> emergencyErase() async {
    emergencyEraseCalls++;
  }

  @override
  Future<int> sweepExpiredMessages() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('viska_duress_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('Duress PIN & Decoy Vault Controller Tests', () {
    test('normal PIN unlocks normally and clears locked state', () async {
      final core = _FakeCore();
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(shouldSucceed: false),
      );

      await controller.setNormalPin('1234');
      expect(controller.hasNormalPin, isTrue);
      expect(controller.isNormalPin('1234'), isTrue);
      expect(controller.isNormalPin('0000'), isFalse);

      await controller.lock();
      expect(controller.isLocked.value, isTrue);

      final unlocked = await controller.verifyAndUnlockWithPin('1234');
      expect(unlocked, isTrue);
      expect(controller.isLocked.value, isFalse);
      expect(controller.isDecoyVault.value, isFalse);
      expect(core.unlockCalls, 1);

      controller.dispose();
    });

    test('duress PIN with mode 0 (Destruição Silenciosa) triggers emergencyErase and exit', () async {
      final core = _FakeCore();
      var exitCode = -1;

      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(shouldSucceed: false),
        exitFn: (code) {
          exitCode = code;
        },
      );

      await controller.setNormalPin('1234');
      await controller.setDuressPin('9999', actionMode: 0);
      expect(controller.hasDuressPin, isTrue);
      expect(controller.isDuressPin('9999'), isTrue);

      await controller.lock();

      final result = await controller.verifyAndUnlockWithPin('9999');
      expect(result, isFalse);
      expect(core.emergencyEraseCalls, 1);
      expect(exitCode, 0);

      controller.dispose();
    });

    test('duress PIN with mode 1 (Cofre Falso) activates decoy vault without erasing real data', () async {
      final core = _FakeCore();
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(shouldSucceed: false),
      );

      await controller.setNormalPin('1234');
      await controller.setDuressPin('8888', actionMode: 1);
      expect(controller.duressActionMode, 1);

      await controller.lock();

      final result = await controller.verifyAndUnlockWithPin('8888');
      expect(result, isTrue);
      expect(controller.isLocked.value, isFalse);
      expect(controller.isDecoyVault.value, isTrue);
      expect(core.emergencyEraseCalls, 0);

      // Bloquear novamente reseta o cofre falso
      await controller.lock();
      expect(controller.isDecoyVault.value, isFalse);
      expect(controller.isLocked.value, isTrue);

      controller.dispose();
    });
  });

  group('LockScreen Duress PIN Interaction Widget Tests', () {
    testWidgets('typing duress PIN on LockScreen executes silent destruction', (tester) async {
      final core = _FakeCore();
      var exitCode = -1;

      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(shouldSucceed: false),
        exitFn: (code) {
          exitCode = code;
        },
      );

      await controller.setNormalPin('1111');
      await controller.setDuressPin('9999', actionMode: 0);
      await controller.lock();

      await tester.pumpWidget(
        MaterialApp(
          home: LockScreen(controller: controller),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Viska Bloqueado'), findsOneWidget);

      // Digita o PIN de coação
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.widgetWithText(FilledButton, 'Entrar com PIN'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(core.emergencyEraseCalls, 1);
      expect(exitCode, 0);

      controller.dispose();
    });
  });
}
