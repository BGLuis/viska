import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_view.dart';
import 'package:viska/src/rust/ffi/types.dart';

void main() {
  testWidgets('renders 12 digit groups and 6 words', (
    WidgetTester tester,
  ) async {
    const safetyNumber = SafetyNumberDto(
      digits: '00000 11111 22222 33333 44444 55555 '
          '66666 77777 88888 99999 12345 67890',
      words: 'abacate abaixo abalar abater abduzir abelha',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SafetyNumberView(safetyNumber: safetyNumber)),
      ),
    );

    final digitsWrap = tester.widget<Wrap>(
      find.byKey(const ValueKey('safety_number_digits')),
    );
    final wordsWrap = tester.widget<Wrap>(
      find.byKey(const ValueKey('safety_number_words')),
    );

    expect(digitsWrap.children, hasLength(12));
    expect(wordsWrap.children, hasLength(6));

    for (final group in safetyNumber.digits.split(' ')) {
      expect(find.text(group), findsOneWidget);
    }
    for (final word in safetyNumber.words.split(' ')) {
      expect(find.text(word), findsOneWidget);
    }
  });
}
