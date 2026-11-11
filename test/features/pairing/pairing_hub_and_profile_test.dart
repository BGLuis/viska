import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/onboarding/profile_setup_dialog.dart';
import 'package:viska/src/common_widgets/actions/viska_button.dart';
import 'package:viska/src/features/pairing/pairing_hub_screen.dart';
import 'package:viska/src/features/pairing/screens/pairing_rejected_screen.dart';
import 'package:viska/src/rust/ffi/error.dart';
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

  bool failMyPayload = false;
  FfiError? pairError;

  @override
  Future<Uint8List> myQrPayload() async {
    if (failMyPayload) throw FfiError.locked;
    return Uint8List.fromList(List.generate(145, (i) => (i + 5) % 256));
  }

  @override
  Future<ContactDto> pairFromQr({required List<int> payload, String? nickname}) async {
    if (pairError != null) throw pairError!;
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
    Future<void> pumpHub(WidgetTester tester, _FakeHubCore core, {int tab = 2}) async {
      await tester.pumpWidget(
        MaterialApp(home: PairingHubScreen(core: core, initialTabIndex: tab)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    ViskaButton addButton(WidgetTester tester) => tester.widget<ViskaButton>(
          find.widgetWithText(ViskaButton, 'Adicionar contato'),
        );

    testWidgets('displays all 3 tabs and allows switching between them', (tester) async {
      final core = _FakeHubCore();
      await pumpHub(tester, core);

      expect(find.text('Adicionar contato'), findsWidgets);
      expect(find.text('Proximidade'), findsOneWidget);
      expect(find.text('QR Code'), findsOneWidget);
      expect(find.text('Código'), findsOneWidget);

      expect(find.text('Código da outra pessoa'), findsOneWidget);

      await tester.tap(find.text('QR Code'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // "Meu código" é a vista inicial: abrir a aba não pede a câmera.
      expect(find.text('Meu código'), findsOneWidget);
      expect(find.text('Escanear'), findsOneWidget);
      expect(
        find.text('Peça para a outra pessoa abrir o Viska e escanear este código. Depois, escaneie o dela.'),
        findsOneWidget,
      );
      expect(find.textContaining('Faça isso pessoalmente.'), findsOneWidget);

      await tester.tap(find.text('Proximidade'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Procurando no mesmo Wi-Fi...'), findsOneWidget);
    });

    testWidgets('Code tab only shows the own code and never offers to copy it', (tester) async {
      final core = _FakeHubCore();
      await pumpHub(tester, core);

      expect(find.textContaining('Copiar'), findsNothing);
      await tester.tap(find.text('Mostrar para a outra pessoa'));
      await tester.pump();

      expect(find.text(base64Encode(await core.myQrPayload())), findsOneWidget);
      expect(mockClipboard, isNull);
    });

    testWidgets('Add button stays disabled until a code is entered', (tester) async {
      final core = _FakeHubCore();
      await pumpHub(tester, core);

      expect(addButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(addButton(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'AAAA');
      await tester.pump();
      expect(addButton(tester).onPressed, isNotNull);
    });

    testWidgets('pasting fills the field without pairing on its own', (tester) async {
      final core = _FakeHubCore();
      mockClipboard = base64Encode(List.generate(145, (i) => i));
      await pumpHub(tester, core);

      await tester.tap(find.byTooltip('Colar'));
      await tester.pump();
      await tester.pump();

      expect(find.text(mockClipboard!), findsOneWidget);
      expect(core.pairedPayload, isNull);
    });

    testWidgets('accepts a valid code split across lines and pairs on demand', (tester) async {
      final core = _FakeHubCore();
      final validPayload = Uint8List.fromList(List.generate(145, (i) => i));
      final b64 = base64Encode(validPayload);
      await pumpHub(tester, core);

      final half = b64.length ~/ 2;
      await tester.enterText(find.byType(TextField), '${b64.substring(0, half)}\n ${b64.substring(half)}');
      await tester.pump();
      await tester.tap(find.widgetWithText(ViskaButton, 'Adicionar contato'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(core.pairedPayload, equals(validPayload));
    });

    testWidgets('invalid code error does not leak encoding details', (tester) async {
      final core = _FakeHubCore();
      await pumpHub(tester, core);

      await tester.enterText(find.byType(TextField), 'não é base64!');
      await tester.pump();
      await tester.tap(find.widgetWithText(ViskaButton, 'Adicionar contato'));
      await tester.pump();

      expect(
        find.text('Código inválido. Confira se ele foi digitado ou colado por inteiro.'),
        findsOneWidget,
      );
      expect(find.textContaining('Base64'), findsNothing);
      expect(find.textContaining('145'), findsNothing);
      expect(core.pairedPayload, isNull);
    });

    testWidgets('key mismatch opens the dedicated rejection screen', (tester) async {
      final core = _FakeHubCore()..pairError = FfiError.contactKeyMismatch;
      await pumpHub(tester, core);

      await tester.enterText(find.byType(TextField), base64Encode(List.generate(145, (i) => i)));
      await tester.pump();
      await tester.tap(find.widgetWithText(ViskaButton, 'Adicionar contato'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(PairingRejectedScreen), findsOneWidget);
    });

    testWidgets('own code failure offers retry instead of spinning forever', (tester) async {
      final core = _FakeHubCore()..failMyPayload = true;
      await pumpHub(tester, core, tab: 1);

      expect(find.text('Não foi possível gerar o seu código.'), findsOneWidget);

      core.failMyPayload = false;
      await tester.tap(find.text('Tentar de novo'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Não foi possível gerar o seu código.'), findsNothing);
    });
  });
}
