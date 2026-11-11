import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/common_widgets/security/sas_code_widget.dart';

void main() {
  group('SasCodeWidget Tests', () {
    testWidgets('renders 6 digits in two groups of three', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SasCodeWidget(sasCode: '492183'),
          ),
        ),
      );

      expect(find.text('492'), findsOneWidget);
      expect(find.text('183'), findsOneWidget);
    });

    testWidgets('handles code with space gracefully', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SasCodeWidget(sasCode: '851 329'),
          ),
        ),
      );

      expect(find.text('851'), findsOneWidget);
      expect(find.text('329'), findsOneWidget);
    });
  });
}
