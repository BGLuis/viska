import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/onboarding/profile_setup_dialog.dart';
import 'package:viska/src/features/pairing/pairing_hub_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _FakeHubCore implements Core {
  String? savedMyNickname;
  List<int>? pairedPayload;
  String? pairedNickname;

  @override
  Future<String?> myNickname() async => savedMyNickname;

  @override
  Future<void> setMyNickname({required String nickname}) async {
    savedMyNickname = nickname;
  }

  @override
  Future<Uint8List> myQrPayload() async =>
      Uint8List.fromList(List.generate(145, (i) => (i + 5) % 256));

  @override
  Future<ContactDto> pairFromQr({required List<int> payload, String? nickname}) async {
    pairedPayload = payload;
    pairedNickname = nickname;
    return ContactDto(
      deviceId: Uint8List.fromList(List.generate(16, (i) => i)),
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 1234567890,
      nickname: nickname ?? 'Par Teste',
      isVerified: false,
    );
  }

  @override
  Future<String> computeSasCode({required List<int> peerPayload}) async => '123456';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String? mockClipboard;

  setUp(() {
    mockClipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        mockClipboard = (call.arguments as Map)['text'] as String?;
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': mockClipboard};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('ProfileSetupDialog', () {
    testWidgets('validates empty field and saves valid nickname', (tester) async {
      final core = _FakeHubCore();
      String? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await ProfileSetupDialog.show(
                    context,
                    core: core,
                    initialNickname: null,
                    isInitialOnboarding: true,
                  );
                },
                child: const Text('Abrir Diálogo'),
              ),
            ),
          ),
        ),
      );

      // Abre o diálogo
      await tester.tap(find.text('Abrir Diálogo'));
      await tester.pumpAndSettle();

      expect(find.text('Bem-vindo ao Viska'), findsOneWidget);
      expect(find.text('Salvar'), findsOneWidget);

      // Tenta salvar vazio
      await tester.tap(find.text('Salvar'));
      await tester.pump();
      expect(find.text('Informe um nome ou apelido.'), findsOneWidget);
      expect(core.savedMyNickname, isNull);

      // Digita um apelido válido
      await tester.enterText(find.byType(TextField), 'Alice');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(core.savedMyNickname, equals('Alice'));
      expect(result, equals('Alice'));
    });
  });

  group('PairingHubScreen', () {
    testWidgets('displays all 3 tabs and allows switching between them', (tester) async {
      final core = _FakeHubCore();

      await tester.pumpWidget(
        MaterialApp(
          home: PairingHubScreen(core: core, initialTabIndex: 2),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Adicionar Contato'), findsOneWidget);
      expect(find.text('Proximidade'), findsOneWidget);
      expect(find.text('QR Code'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);

      // Na aba manual inicializada
      expect(find.text('Inserir código recebido'), findsOneWidget);
      expect(find.text('Parear Contato'), findsOneWidget);

      // Alterna para QR Code
      await tester.tap(find.text('QR Code'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Escanear amigo'), findsOneWidget);
      expect(find.text('Meu código'), findsOneWidget);

      // Alterna para Proximidade
      await tester.tap(find.text('Proximidade'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Procurando aparelhos próximos na rede local...'), findsOneWidget);
    });

    testWidgets('Manual tab validates Base64 code and executes pairing', (tester) async {
      final core = _FakeHubCore();
      final validPayload = Uint8List.fromList(List.generate(145, (i) => i));
      final b64 = base64Encode(validPayload);

      await tester.pumpWidget(
        MaterialApp(
          home: PairingHubScreen(core: core, initialTabIndex: 2),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Digita código válido
      final textFields = find.byType(TextField);
      expect(textFields, findsOneWidget);
      await tester.enterText(textFields.first, b64);

      await tester.tap(find.text('Parear Contato'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(core.pairedPayload, equals(validPayload));
    });
  });
}
