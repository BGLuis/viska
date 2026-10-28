import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/features/settings/screens/duress_pin_screen.dart';
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

/// Plataforma sem implementação do local_auth (Linux, alvo de desenvolvimento).
class _NoAuthPluginLocalAuthentication implements LocalAuthentication {
  @override
  Future<bool> get canCheckBiometrics async =>
      throw MissingPluginException('No implementation found for method getAvailableBiometrics');

  @override
  Future<bool> isDeviceSupported() async =>
      throw MissingPluginException('No implementation found for method isDeviceSupported');

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

      // Digita o PIN de coação no teclado in-app
      for (final digit in '9999'.split('')) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(core.emergencyEraseCalls, 1);
      expect(exitCode, 0);

      controller.dispose();
    });
  });

  group('PIN configuration rules', () {
    LockController newController(_FakeCore core, {DateTime Function()? clock}) =>
        LockController(
          core: core,
          appDirPath: tempDir.path,
          localAuth: _FakeLocalAuthentication(shouldSucceed: false),
          exitFn: (_) {},
          clock: clock,
        );

    test('rejects duress PIN equal to the current normal PIN when the normal one is kept', () async {
      final core = _FakeCore();
      final controller = newController(core);
      await controller.setNormalPin('1234');

      await expectLater(
        controller.configurePins(duressPin: '1234', actionMode: 0),
        throwsA(isA<PinConfigException>()),
      );
      expect(controller.hasDuressPin, isFalse);

      // O PIN do dono precisa continuar desbloqueando, não apagando tudo.
      await controller.lock();
      expect(await controller.verifyAndUnlockWithPin('1234'), isTrue);
      expect(core.emergencyEraseCalls, 0);

      controller.dispose();
    });

    test('rejects a new normal PIN equal to the existing duress PIN', () async {
      final controller = newController(_FakeCore());
      await controller.setNormalPin('1234');
      await controller.setDuressPin('9999');

      await expectLater(
        controller.configurePins(normalPin: '9999'),
        throwsA(isA<PinConfigException>()),
      );
      expect(controller.isNormalPin('1234'), isTrue);

      controller.dispose();
    });

    test('rejects duress PIN with a different length from the normal PIN', () async {
      final controller = newController(_FakeCore());
      await controller.setNormalPin('123456');

      await expectLater(
        controller.configurePins(duressPin: '9999'),
        throwsA(isA<PinConfigException>()),
      );

      // Trocar os dois juntos para o mesmo tamanho é válido.
      await controller.configurePins(normalPin: '1234', duressPin: '9999');
      expect(controller.normalPinLength, 4);
      expect(controller.duressPinLength, 4);

      controller.dispose();
    });

    test('rejects PINs the lock screen keypad cannot type', () async {
      final controller = newController(_FakeCore());

      for (final invalid in ['123', '123456789', '12a4', '12 34']) {
        await expectLater(
          controller.setNormalPin(invalid),
          throwsA(isA<PinConfigException>()),
          reason: invalid,
        );
      }
      expect(controller.hasNormalPin, isFalse);

      controller.dispose();
    });

    test('rejects duress PIN without a normal PIN', () async {
      final controller = newController(_FakeCore());

      await expectLater(
        controller.setDuressPin('9999'),
        throwsA(isA<PinConfigException>()),
      );

      controller.dispose();
    });

    test('blocks every PIN, including duress, after repeated failures until the delay expires', () async {
      final core = _FakeCore();
      var now = DateTime(2026, 1, 1);
      final controller = newController(core, clock: () => now);
      await controller.setNormalPin('1234');
      await controller.setDuressPin('9999');
      await controller.lock();

      for (var i = 0; i < LockController.freePinAttempts; i++) {
        expect(await controller.verifyAndUnlockWithPin('0000'), isFalse);
      }
      expect(controller.pinRetryDelay, greaterThan(Duration.zero));

      expect(await controller.verifyAndUnlockWithPin('1234'), isFalse);
      expect(await controller.verifyAndUnlockWithPin('9999'), isFalse);
      expect(core.emergencyEraseCalls, 0);
      expect(controller.isLocked.value, isTrue);

      // A espera sobrevive a reabrir o app.
      final reopened = newController(core, clock: () => now);
      expect(reopened.pinRetryDelay, greaterThan(Duration.zero));
      reopened.dispose();

      now = now.add(const Duration(minutes: 1));
      expect(await controller.verifyAndUnlockWithPin('1234'), isTrue);
      expect(controller.pinRetryDelay, Duration.zero);

      controller.dispose();
    });
  });

  group('LockScreen PIN traps', () {
    testWidgets('does not offer a PIN keypad when no PIN was configured', (tester) async {
      final controller = LockController(
        core: _FakeCore(),
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(shouldSucceed: false),
      );
      await controller.lock();

      await tester.pumpWidget(MaterialApp(home: LockScreen(controller: controller)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Desbloquear'), findsOneWidget);
      expect(find.text('5'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      controller.dispose();
    });

    testWidgets('legacy config with a shorter duress PIN still lets the longer normal PIN be typed', (tester) async {
      String hash(String pin) => sha256.convert(utf8.encode('viska-pin-v1:$pin')).toString();
      File('${tempDir.path}/security_config.json').writeAsStringSync(jsonEncode({
        'normal_pin_hash': hash('123456'),
        'normal_pin_length': 6,
        'duress_pin_hash': hash('9999'),
        'duress_pin_length': 4,
        'duress_action_mode': 0,
      }));

      final core = _FakeCore();
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(shouldSucceed: false),
        exitFn: (_) {},
      );
      await controller.lock();

      await tester.pumpWidget(MaterialApp(home: LockScreen(controller: controller)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      for (final digit in '123456'.split('')) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.isLocked.value, isFalse);
      expect(core.emergencyEraseCalls, 0);

      controller.dispose();
    });
  });

  group('DuressPinScreen', () {
    Future<LockController> pumpScreen(WidgetTester tester, _FakeCore core) async {
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _FakeLocalAuthentication(),
        exitFn: (_) {},
      );
      await controller.setNormalPin('1234');
      await tester.pumpWidget(MaterialApp(home: DuressPinScreen(controller: controller)));
      await tester.pump();
      return controller;
    }

    Finder field(String label) => find.ancestor(
          of: find.text(label),
          matching: find.byType(Column),
        ).first;

    Future<void> typeInto(WidgetTester tester, String label, String text) async {
      await tester.enterText(
        find.descendant(of: field(label), matching: find.byType(TextField)),
        text,
      );
    }

    Future<void> tapButton(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
    }

    testWidgets('refuses to save a duress PIN equal to the kept normal PIN', (tester) async {
      final controller = await pumpScreen(tester, _FakeCore());

      await typeInto(tester, 'PIN atual', '1234');
      await typeInto(tester, 'PIN de Coação (Duress PIN)', '1234');
      await tapButton(tester, 'SALVAR CONFIGURAÇÃO DE PIN');

      expect(find.text('O PIN de Coação não pode ser igual ao PIN Normal.'), findsOneWidget);
      expect(controller.hasDuressPin, isFalse);

      controller.dispose();
    });

    testWidgets('requires the current PIN before removing the PINs', (tester) async {
      final controller = await pumpScreen(tester, _FakeCore());

      await tapButton(tester, 'REMOVER PINS CONFIGURADOS');

      expect(find.text('Digite o PIN atual para remover os PINs.'), findsOneWidget);
      expect(find.text('Remover PINs?'), findsNothing);
      expect(controller.hasNormalPin, isTrue);

      controller.dispose();
    });

    testWidgets('requires the new normal PIN to be confirmed', (tester) async {
      final controller = await pumpScreen(tester, _FakeCore());

      await typeInto(tester, 'PIN atual', '1234');
      await typeInto(tester, 'Novo PIN Normal', '5678');
      await typeInto(tester, 'Confirme o PIN Normal', '5679');
      await tapButton(tester, 'SALVAR CONFIGURAÇÃO DE PIN');

      expect(find.text('A confirmação não coincide com o novo PIN Normal.'), findsOneWidget);
      expect(controller.isNormalPin('1234'), isTrue);

      controller.dispose();
    });
  });

  group('Platform without local_auth implementation', () {
    test('unlocks when no PIN is configured instead of staying locked forever', () async {
      final core = _FakeCore();
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _NoAuthPluginLocalAuthentication(),
      );
      await controller.lock();

      expect(await controller.unlock(), isTrue);
      expect(controller.isLocked.value, isFalse);

      controller.dispose();
    });

    test('still requires the PIN when one is configured', () async {
      final core = _FakeCore();
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: _NoAuthPluginLocalAuthentication(),
      );
      await controller.setNormalPin('1234');
      await controller.lock();

      expect(await controller.unlock(), isFalse);
      expect(controller.isLocked.value, isTrue);
      expect(await controller.verifyAndUnlockWithPin('1234'), isTrue);

      controller.dispose();
    });
  });
}
