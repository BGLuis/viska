import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/common_widgets/security/safety_number_widget.dart';

void main() {
  group('SafetyNumberWidget Tests', () {
    testWidgets('renders 12 blocks and 6 BIP-39 words', (tester) async {
      const digits = '12345 67890 11111 22222 33333 44444 55555 66666 77777 88888 99999 00000';
      const words = 'abacate abaixo abalar abater abduzir abelha';

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SafetyNumberWidget(
              digits: digits,
              words: words,
            ),
          ),
        ),
      );

      final digitsWrap = tester.widget<Wrap>(find.byKey(const ValueKey('safety_number_digits')));
      expect(digitsWrap.children.length, 12);

      final wordsWrap = tester.widget<Wrap>(find.byKey(const ValueKey('safety_number_words')));
      expect(wordsWrap.children.length, 6);

      expect(find.text('OU LEIA EM VOZ ALTA'), findsOneWidget);
      expect(find.text('12345'), findsOneWidget);
      expect(find.text('abacate'), findsOneWidget);
    });
  });
}
