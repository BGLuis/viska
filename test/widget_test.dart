import 'package:flutter_test/flutter_test.dart';
import 'package:viska/main.dart';

void main() {
  testWidgets('Smoke test da aplicação básica', (WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    expect(find.text('Hello World!'), findsOneWidget);
  });
}
