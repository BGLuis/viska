import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_scanner.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _FakePermissionHandlerPlatform extends PermissionHandlerPlatform {
  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    return {
      for (final permission in permissions) permission: PermissionStatus.denied,
    };
  }
}

class _MockCore implements Core {
  final List<Map<String, dynamic>> verifyCalls = [];

  @override
  Future<void> verifyContact({
    required List<int> contactDeviceId,
    required bool verified,
  }) async {
    verifyCalls.add({
      'contactDeviceId': contactDeviceId,
      'verified': verified,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PermissionHandlerPlatform.instance = _FakePermissionHandlerPlatform();

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

  final devIdHex = contact.deviceId
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toLowerCase();

  testWidgets(
      'Valid matching QR payload triggers core.verifyContact, shows success dialog and returns true',
      (tester) async {
    final core = _MockCore();

    await tester.pumpWidget(
      MaterialApp(
        home: SafetyNumberScanner(
          contact: contact,
          expectedSafetyNumber: safetyNumber,
          core: core,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open manual input dialog
    expect(find.byKey(const Key('manual_payload_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('manual_payload_button')));
    await tester.pumpAndSettle();

    // Enter matching payload: viska-sn-v1:<deviceId>:<safetyNumberDigits>
    final matchingPayload = 'viska-sn-v1:$devIdHex:${safetyNumber.digits}';
    await tester.enterText(find.byKey(const Key('manual_input_field')), matchingPayload);
    await tester.tap(find.byKey(const Key('manual_input_submit_button')));
    await tester.pumpAndSettle();

    // Verification happened
    expect(core.verifyCalls.length, 1);
    expect(core.verifyCalls.first['verified'], true);

    // Success dialog is displayed
    expect(find.text('Identidade Verificada Criptograficamente!'), findsOneWidget);
    expect(find.byKey(const Key('verification_dialog_ok_button')), findsOneWidget);

    // Tap conclude button
    await tester.tap(find.byKey(const Key('verification_dialog_ok_button')));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'Mismatched QR payload does not call verifyContact and displays cryptographic mismatch warning',
      (tester) async {
    final core = _MockCore();

    await tester.pumpWidget(
      MaterialApp(
        home: SafetyNumberScanner(
          contact: contact,
          expectedSafetyNumber: safetyNumber,
          core: core,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open manual input dialog
    await tester.tap(find.byKey(const Key('manual_payload_button')));
    await tester.pumpAndSettle();

    // Enter mismatched payload
    const mismatchedPayload =
        'viska-sn-v1:000102030405060708090a0b0c0d0e0f:99999 99999 99999 99999 99999 99999 99999 99999 99999 99999 99999 99999';
    await tester.enterText(find.byKey(const Key('manual_input_field')), mismatchedPayload);
    await tester.tap(find.byKey(const Key('manual_input_submit_button')));
    await tester.pumpAndSettle();

    // verifyContact was NOT called
    expect(core.verifyCalls, isEmpty);

    // Error banner is displayed
    expect(
      find.textContaining('O Safety Number lido NÃO confere com este contato!'),
      findsOneWidget,
    );
  });

  testWidgets('Invalid prefix payload displays format incompatibility error',
      (tester) async {
    final core = _MockCore();

    await tester.pumpWidget(
      MaterialApp(
        home: SafetyNumberScanner(
          contact: contact,
          expectedSafetyNumber: safetyNumber,
          core: core,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open manual input dialog
    await tester.tap(find.byKey(const Key('manual_payload_button')));
    await tester.pumpAndSettle();

    // Enter invalid payload
    await tester.enterText(find.byKey(const Key('manual_input_field')), 'https://malicious.link');
    await tester.tap(find.byKey(const Key('manual_input_submit_button')));
    await tester.pumpAndSettle();

    expect(core.verifyCalls, isEmpty);
    expect(find.text('QR Code inválido: formato incompatível.'), findsOneWidget);
  });
}
