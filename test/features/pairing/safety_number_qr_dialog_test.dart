import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_qr_dialog.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_view.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _MockCore implements Core {
  final Uint8List myDevId;
  _MockCore({Uint8List? myDevId})
      : myDevId = myDevId ?? Uint8List.fromList(List.filled(16, 0xAA));

  @override
  Future<Uint8List> myDeviceId() async => myDevId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final contact = ContactDto(
    deviceId: Uint8List.fromList(List.generate(16, (i) => i)),
    signingPubkey: Uint8List(32),
    dhPubkey: Uint8List(32),
    pairedAtUnixSecs: 1000,
    nickname: 'Alice Segura',
    isVerified: false,
  );

  const safetyNumber = SafetyNumberDto(
    digits: '12345 67890 11111 22222 33333 44444 55555 66666 77777 88888 99999 00000',
    words: 'palavra1 palavra2 palavra3 palavra4 palavra5',
  );

  testWidgets('SafetyNumberQrDialog displays QR code, formatted digits and scan button',
      (tester) async {
    final core = _MockCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafetyNumberQrDialog(
            contact: contact,
            safetyNumber: safetyNumber,
            core: core,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Nickname and title
    expect(find.textContaining('Alice Segura'), findsOneWidget);

    // QR Image View
    expect(find.byType(QrImageView), findsOneWidget);

    // Digits view
    expect(find.byType(SafetyNumberView), findsOneWidget);

    // Partner scan button
    expect(find.byKey(const Key('scan_partner_qr_button')), findsOneWidget);
    expect(find.text('Escanear QR do parceiro'), findsOneWidget);

    // Unverified contact does not show verified badge in title
    expect(find.byKey(const Key('dialog_verified_badge')), findsNothing);
  });

  testWidgets('SafetyNumberQrDialog displays verified badge when contact is verified',
      (tester) async {
    final core = _MockCore();
    final verifiedContact = ContactDto(
      deviceId: Uint8List.fromList(List.generate(16, (i) => i)),
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 1000,
      nickname: 'Bob Confiável',
      isVerified: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafetyNumberQrDialog(
            contact: verifiedContact,
            safetyNumber: safetyNumber,
            core: core,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dialog_verified_badge')), findsOneWidget);
  });
}
