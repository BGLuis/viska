import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/common_widgets/actions/hold_to_confirm_button.dart';

void main() {
  group('HoldToConfirmButton Widget Tests', () {
    testWidgets('tap without holding does not trigger onConfirmed', (tester) async {
      var confirmed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HoldToConfirmButton(
              label: 'SEGURE PARA CONFIRMAR',
              holdDuration: const Duration(milliseconds: 500),
              onConfirmed: () => confirmed = true,
            ),
          ),
        ),
      );

      // Toque rápido de 100ms
      final gesture = await tester.startGesture(tester.getCenter(find.text('SEGURE PARA CONFIRMAR')));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(confirmed, isFalse);
    });

    testWidgets('holding for full duration triggers onConfirmed', (tester) async {
      var confirmed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HoldToConfirmButton(
              label: 'SEGURE PARA CONFIRMAR',
              holdDuration: const Duration(milliseconds: 500),
              onConfirmed: () => confirmed = true,
            ),
          ),
        ),
      );

      // Pressiona e segura por 600ms
      final gesture = await tester.startGesture(tester.getCenter(find.text('SEGURE PARA CONFIRMAR')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(confirmed, isTrue);
    });
  });
}
