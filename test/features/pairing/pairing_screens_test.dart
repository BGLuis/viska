import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:viska/src/features/pairing/pairing_scan_screen.dart';
import 'package:viska/src/features/pairing/pairing_show_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _FakeCore implements Core {
  _FakeCore({this.qrPayload});

  final Uint8List? qrPayload;
  List<int>? pairedPayload;

  @override
  Future<Uint8List> myQrPayload() async =>
      qrPayload ?? Uint8List.fromList(List.generate(145, (i) => i % 256));

  @override
  Future<ContactDto> pairFromQr({required List<int> payload}) async {
    pairedPayload = payload;
    return ContactDto(
      deviceId: Uint8List.fromList(List.generate(16, (i) => i)),
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 1234567890,
      nickname: 'Amigo Teste',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePermissionHandlerPlatform extends PermissionHandlerPlatform {
  var denyCamera = true;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    return {
      for (final permission in permissions)
        permission: denyCamera && permission == Permission.camera
            ? PermissionStatus.denied
            : PermissionStatus.granted,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? mockClipboardText;
  late PermissionHandlerPlatform previousPermissionPlatform;

  setUp(() {
    mockClipboardText = null;
    previousPermissionPlatform = PermissionHandlerPlatform.instance;
    PermissionHandlerPlatform.instance = _FakePermissionHandlerPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        mockClipboardText = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': mockClipboardText};
      }
      return null;
    });
  });

  tearDown(() {
    PermissionHandlerPlatform.instance = previousPermissionPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('PairingShowScreen exibe QR e copia codigo Base64 ao clicar', (
    WidgetTester tester,
  ) async {
    final payload = Uint8List.fromList(List.generate(145, (i) => i + 1));
    final fakeCore = _FakeCore(qrPayload: payload);

    await tester.pumpWidget(
      MaterialApp(home: PairingShowScreen(core: fakeCore)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Meu código'), findsOneWidget);
    expect(find.text('Copiar código'), findsOneWidget);

    await tester.tap(find.text('Copiar código'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    final clipData = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipData?.text, equals(base64Encode(payload)));
    expect(find.text('Código de pareamento copiado.'), findsOneWidget);
  });

  testWidgets('PairingScanScreen nao cracha sem camera e suporta colar codigo', (
    WidgetTester tester,
  ) async {
    final payload = Uint8List.fromList(List.generate(145, (i) => 42));
    final base64Payload = base64Encode(payload);
    final fakeCore = _FakeCore();

    // Configura o clipboard com o payload
    mockClipboardText = base64Payload;

    await tester.pumpWidget(
      MaterialApp(home: PairingScanScreen(core: fakeCore)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Escanear código'), findsOneWidget);
    expect(find.text('Colar código copiado'), findsOneWidget);

    // Toca no botão de colar código
    await tester.tap(find.text('Colar código copiado'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(fakeCore.pairedPayload, equals(payload));
  });
}
