import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/lock/inactivity_detector.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/rust/ffi/core.dart';

class _FakeCore implements Core {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SpyLockController extends LockController {
  _SpyLockController({required super.core, required super.appDirPath});

  int userInteractionCount = 0;

  @override
  void onUserInteraction() {
    userInteractionCount++;
    super.onUserInteraction();
  }
}

void main() {
  testWidgets('InactivityDetector notifies controller on pointer down and pointer move', (
    WidgetTester tester,
  ) async {
    final controller = _SpyLockController(
      core: _FakeCore(),
      appDirPath: '/tmp/viska_test',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InactivityDetector(
          controller: controller,
          child: const Scaffold(
            body: Center(child: Text('Conteúdo Viska')),
          ),
        ),
      ),
    );

    expect(controller.userInteractionCount, 0);

    // Simula toque (pointer down)
    final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.down(tester.getCenter(find.text('Conteúdo Viska')));
    expect(controller.userInteractionCount, 1);

    // Simula arrasto / movimento (pointer move)
    await gesture.moveBy(const Offset(10, 10));
    expect(controller.userInteractionCount, 2);

    await gesture.up();
    controller.dispose();
  });
}
