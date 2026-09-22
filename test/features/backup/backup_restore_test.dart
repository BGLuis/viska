import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:viska/src/features/backup/backup_screen.dart';
import 'package:viska/src/features/backup/restore_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.tempDir);

  final Directory tempDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir.path;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir.path;
}

class _FakeCore implements Core {
  String? lastExportDestPath;
  String? lastRestoreSrcPath;
  String? lastRestoreMnemonic;
  var throwOnRestore = false;

  static const sample24Words =
      'abacate abelha abismo abrigo abuso acampamento aceso acerto acolher aco '
      'acucar adesivo adorar adubo afeto afiar afluente afogar afronte agasalho '
      'agilidade agonia agora agudo';

  @override
  Future<String> exportEncryptedBackup({required String destPath}) async {
    lastExportDestPath = destPath;
    final file = File(destPath);
    file.writeAsStringSync('viskasafe-dummy-encrypted-bytes');
    return sample24Words;
  }

  @override
  Future<void> restoreEncryptedBackup({
    required String srcPath,
    required String mnemonic,
  }) async {
    if (throwOnRestore) {
      throw StateError('arquivo corrompido');
    }
    lastRestoreSrcPath = srcPath;
    lastRestoreMnemonic = mnemonic;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('viska_backup_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    tempDir.deleteSync(recursive: true);
  });

  group('BackupScreen Widget Tests', () {
    testWidgets('exports backup, displays 24 words in numbered chips, and shows file path', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: BackupScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Exportar Backup Cifrado'), findsOneWidget);
      expect(find.text('FRASE MNEMÔNICA (24 PALAVRAS)'), findsOneWidget);

      // Confere palavras exibidas
      expect(find.text('abacate'), findsOneWidget);
      expect(find.text('agudo'), findsOneWidget);
      expect(find.text('01'), findsOneWidget);
      expect(find.text('24'), findsOneWidget);

      // Confere aviso de segurança
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

      // Seção do contêiner cifrado
      expect(find.text('CONTÊINER CIFRADO (.VISKASAFE)'), findsOneWidget);

      // Confere que gerou o arquivo no disco
      expect(core.lastExportDestPath, isNotNull);
      expect(find.text(core.lastExportDestPath!), findsOneWidget);
    });

    testWidgets('copy words button shows SnackBar confirmation', (
      WidgetTester tester,
    ) async {
      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: BackupScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      final copyButton = find.widgetWithText(TextButton, 'Copiar Todas');
      expect(copyButton, findsOneWidget);
      await tester.tap(copyButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('24 palavras copiadas para a área de transferência.'),
        findsOneWidget,
      );
    });
  });

  group('RestoreScreen Widget Tests', () {
    testWidgets('validates 24 words requirement before restore', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: RestoreScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      // Digita apenas 3 palavras
      final mnemonicField = find.byType(TextField).first;
      await tester.enterText(mnemonicField, 'abacate abelha abismo');
      await tester.pumpAndSettle();

      expect(find.text('3 / 24 palavras'), findsOneWidget);

      // Toca no botão de restauração
      final restoreButton = find.byKey(const Key('restore_backup_button'));
      await tester.tap(restoreButton);
      await tester.pumpAndSettle();

      expect(
        find.text('A frase mnemônica precisa ter exatamente 24 palavras (atualmente: 3).'),
        findsOneWidget,
      );
    });

    testWidgets('successful restore triggers core and onRestored callback', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final core = _FakeCore();
      var restoredCallbackCalled = false;

      final backupFile = File('${tempDir.path}/test_backup.viskasafe');
      backupFile.writeAsStringSync('dummy-backup-content');

      await tester.pumpWidget(
        MaterialApp(
          home: RestoreScreen(
            core: core,
            onRestored: () {
              restoredCallbackCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Insere as 24 palavras
      final mnemonicField = find.byType(TextField).first;
      await tester.enterText(mnemonicField, _FakeCore.sample24Words);
      await tester.pumpAndSettle();

      expect(find.text('24 / 24 palavras'), findsOneWidget);

      // Insere o caminho do arquivo
      final pathField = find.widgetWithText(TextField, 'Caminho do arquivo');
      await tester.enterText(pathField, backupFile.path);
      await tester.pumpAndSettle();

      // Clica em restaurar
      final restoreButton = find.byKey(const Key('restore_backup_button'));
      await tester.tap(restoreButton);
      await tester.pumpAndSettle();

      // Diálogo de confirmação deve aparecer
      expect(find.text('Confirmar Restauração'), findsOneWidget);
      await tester.tap(find.text('Restaurar Agora'));
      await tester.pumpAndSettle();

      expect(core.lastRestoreSrcPath, backupFile.path);
      expect(core.lastRestoreMnemonic, _FakeCore.sample24Words);
      expect(restoredCallbackCalled, isTrue);
    });
  });
}
