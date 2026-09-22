import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/settings/settings_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';

class _FakeCore implements Core {
  var lockCalls = 0;
  var emergencyEraseCalls = 0;

  @override
  Future<void> lock() async {
    lockCalls++;
  }

  @override
  Future<void> emergencyErase() async {
    emergencyEraseCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('SettingsScreen toggles autoLockOnBackground and updates controller', (
    WidgetTester tester,
  ) async {
    final core = _FakeCore();
    final controller = LockController(
      core: core,
      appDirPath: '/tmp/viska_test',
      autoLockOnBackground: true,
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bloquear ao suspender'), findsOneWidget);
    expect(controller.autoLockOnBackground, isTrue);

    // Toca no switch para desativar
    await tester.tap(find.text('Bloquear ao suspender'));
    await tester.pumpAndSettle();

    expect(controller.autoLockOnBackground, isFalse);

    controller.dispose();
  });

  testWidgets('SettingsScreen changes autoLockTimeout via dropdown', (
    WidgetTester tester,
  ) async {
    final core = _FakeCore();
    final controller = LockController(
      core: core,
      appDirPath: '/tmp/viska_test',
      autoLockTimeout: const Duration(seconds: 60),
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 minuto de inatividade'), findsOneWidget);

    // Abre o dropdown
    await tester.tap(find.text('1 minuto'));
    await tester.pumpAndSettle();

    // Seleciona 5 minutos
    await tester.tap(find.text('5 minutos').last);
    await tester.pumpAndSettle();

    expect(controller.autoLockTimeout, const Duration(seconds: 300));

    controller.dispose();
  });

  testWidgets('tapping Bloquear agora triggers controller.lock', (
    WidgetTester tester,
  ) async {
    final core = _FakeCore();
    final controller = LockController(
      core: core,
      appDirPath: '/tmp/viska_test',
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bloquear agora'));
    await tester.pumpAndSettle();

    expect(core.lockCalls, 1);
    expect(controller.isLocked.value, isTrue);

    controller.dispose();
  });

  testWidgets('Emergency erase dialog requires typing DESTRUIR DADOS to activate button', (
    WidgetTester tester,
  ) async {
    final core = _FakeCore();
    final controller = LockController(
      core: core,
      appDirPath: '/tmp/viska_test',
    );

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    // Abre diálogo de emergência
    await tester.tap(find.text('Apagamento de emergência'));
    await tester.pumpAndSettle();

    expect(find.text('Destruição Irreversível'), findsOneWidget);

    final destroyButtonFinder = find.widgetWithText(ElevatedButton, 'Destruir Tudo');
    expect(destroyButtonFinder, findsOneWidget);

    // Botão inicialmente desabilitado
    ElevatedButton destroyButton = tester.widget(destroyButtonFinder);
    expect(destroyButton.onPressed, isNull);

    // Digita texto incorreto
    await tester.enterText(find.byType(TextField), 'destruir');
    await tester.pumpAndSettle();

    destroyButton = tester.widget(destroyButtonFinder);
    expect(destroyButton.onPressed, isNull);

    // Digita o texto exato requerido
    await tester.enterText(find.byType(TextField), 'DESTRUIR DADOS');
    await tester.pumpAndSettle();

    destroyButton = tester.widget(destroyButtonFinder);
    expect(destroyButton.onPressed, isNotNull);

    // Executa apagamento de emergência
    await tester.tap(destroyButtonFinder);
    await tester.pumpAndSettle();

    expect(core.emergencyEraseCalls, 1);
    expect(controller.isLocked.value, isTrue);

    controller.dispose();
  });
}
