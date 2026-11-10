import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/settings/auto_accept_limit_tile.dart';
import 'package:viska/src/features/settings/settings_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';

const _mib = 1024 * 1024;

class _FakeCore implements Core {
  _FakeCore(this.limit);

  int limit;
  bool failRead = false;
  bool failWrite = false;
  final writes = <BigInt>[];

  @override
  Future<BigInt> autoAcceptFileSizeLimit() async {
    if (failRead) throw StateError('leitura');
    return BigInt.from(limit);
  }

  @override
  Future<void> setAutoAcceptFileSizeLimit({required BigInt limitBytes}) async {
    if (failWrite) throw StateError('gravação');
    writes.add(limitBytes);
    limit = limitBytes.toInt();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<LockController> _pump(WidgetTester tester, _FakeCore core) async {
  final controller = LockController(core: core, appDirPath: '/tmp/viska_test');
  await tester.pumpWidget(MaterialApp(home: SettingsScreen(controller: controller)));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('Auto-aceite de arquivos'), 100);
  await tester.ensureVisible(find.byType(AutoAcceptLimitTile));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _choose(WidgetTester tester, String current, String target) async {
  await tester.tap(find.text(current));
  await tester.pumpAndSettle();
  await tester.tap(find.text(target).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('auto-accept limit shows core value and writes chosen bytes', (tester) async {
    final core = _FakeCore(100 * _mib);
    final controller = await _pump(tester, core);

    expect(find.text('100 MiB'), findsOneWidget);
    await _choose(tester, '100 MiB', '500 MiB');

    expect(core.writes, [BigInt.from(500 * _mib)]);
    expect(find.text('500 MiB'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('auto-accept limit outside the list is shown formatted', (tester) async {
    final core = _FakeCore(1536 * _mib);
    final controller = await _pump(tester, core);

    expect(find.text('1,5 GiB'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('auto-accept limit write failure shows error and keeps previous value', (tester) async {
    final core = _FakeCore(100 * _mib)..failWrite = true;
    final controller = await _pump(tester, core);

    await _choose(tester, '100 MiB', '25 MiB');

    expect(find.text('Não foi possível salvar o limite de auto-aceite.'), findsOneWidget);
    expect(find.text('100 MiB'), findsOneWidget);
    expect(core.writes, isEmpty);

    controller.dispose();
  });

  testWidgets('auto-accept limit zero is labelled Sempre perguntar', (tester) async {
    final core = _FakeCore(25 * _mib);
    final controller = await _pump(tester, core);

    await _choose(tester, '25 MiB', 'Sempre perguntar');

    expect(core.writes, [BigInt.zero]);
    expect(find.text('Todo arquivo recebido pede confirmação'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('auto-accept limit read failure disables the menu', (tester) async {
    final core = _FakeCore(100 * _mib)..failRead = true;
    final controller = await _pump(tester, core);

    expect(find.text('Não foi possível ler o limite'), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<int>>(find.byType(DropdownButton<int>).last);
    expect(dropdown.onChanged, isNull);

    controller.dispose();
  });

  test('formatAutoAcceptLimit uses binary units', () {
    expect(formatAutoAcceptLimit(10000), '9,8 KiB');
    expect(formatAutoAcceptLimit(512), '512 B');
    expect(formatAutoAcceptLimit(10 * _mib), '10 MiB');
    expect(formatAutoAcceptLimit(1024 * _mib), '1 GiB');
  });
}
