import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/common_widgets/chat/file_offer_card.dart';

void main() {
  group('FileOfferCard Tests', () {
    testWidgets('renders filename, formatted size, and buttons', (tester) async {
      var accepted = false;
      var rejected = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileOfferCard(
              fileName: 'backup_archive.tar.gz',
              fileSizeBytes: 150 * 1024 * 1024, // 150 MB
              onAccept: () => accepted = true,
              onReject: () => rejected = true,
            ),
          ),
        ),
      );

      expect(find.text('backup_archive.tar.gz'), findsOneWidget);
      expect(find.textContaining('150.0 MB'), findsOneWidget);
      expect(find.text('Aceitar'), findsOneWidget);
      expect(find.text('Recusar'), findsOneWidget);

      await tester.tap(find.text('Aceitar'));
      await tester.pump();
      expect(accepted, isTrue);

      await tester.tap(find.text('Recusar'));
      await tester.pump();
      expect(rejected, isTrue);
    });
  });
}
