import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/common_widgets/security/pin_dots.dart';
import 'package:viska/src/common_widgets/security/pin_pad.dart';

void main() {
  group('PinPad and PinDots Widget Tests', () {
    testWidgets('PinDots renders correctly for filled and empty counts', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PinDots(
              length: 6,
              filledCount: 3,
              hasError: false,
            ),
          ),
        ),
      );

      // Encontra o Container do PinDots
      final row = tester.widget<Row>(find.byType(Row));
      expect(row.children.length, 6);
    });

    testWidgets('PinPad taps emit expected digits and backspace', (tester) async {
      final pressedDigits = <String>[];
      var backspaceCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PinPad(
              onDigitPressed: (digit) => pressedDigits.add(digit),
              onBackspacePressed: () => backspaceCount++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('1'));
      await tester.tap(find.text('5'));
      await tester.tap(find.text('9'));
      await tester.tap(find.text('0'));

      final backspace = find.byIcon(Icons.backspace_outlined);
      expect(backspace, findsOneWidget);
      await tester.tap(backspace);

      expect(pressedDigits, ['1', '5', '9', '0']);
      expect(backspaceCount, 1);
    });
  });
}
