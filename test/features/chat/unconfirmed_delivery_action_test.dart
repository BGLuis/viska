import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/chat/widgets/unconfirmed_delivery_action.dart';

void main() {
  testWidgets('warns about a possible duplicate before resending', (
    tester,
  ) async {
    var resends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnconfirmedDeliveryAction(
            label: 'Não confirmada',
            onResend: () => resends++,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('resend_unknown_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('duas vezes'), findsOneWidget);
    expect(resends, 0);

    await tester.tap(find.byKey(const Key('resend_unknown_confirm')));
    await tester.pumpAndSettle();

    expect(resends, 1);
  });

  testWidgets('does not resend when the person cancels', (tester) async {
    var resends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnconfirmedDeliveryAction(
            label: 'Não confirmada',
            onResend: () => resends++,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('resend_unknown_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('resend_unknown_cancel')));
    await tester.pumpAndSettle();

    expect(resends, 0);
  });

  testWidgets('shows the unconfirmed label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnconfirmedDeliveryAction(
            label: 'Não confirmada',
            onResend: () {},
          ),
        ),
      ),
    );

    expect(find.text('Não confirmada'), findsOneWidget);
  });
}
