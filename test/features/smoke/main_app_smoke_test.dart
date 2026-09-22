import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:viska/main.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';

class _MockSmokeCore implements Core {
  _MockSmokeCore({
    List<ContactDto>? contacts,
  }) : _contacts = contacts ?? [];

  String? nickname = 'Luis Teste';
  final List<ContactDto> _contacts;
  int lockCalls = 0;
  int unlockCalls = 0;
  int sweepCalls = 0;

  @override
  Future<String?> myNickname() async => nickname;

  @override
  Future<void> setMyNickname({required String nickname}) async {
    this.nickname = nickname;
  }

  @override
  Future<List<ContactDto>> listContacts() async => _contacts;

  @override
  Future<Uint8List> myQrPayload() async =>
      Uint8List.fromList(List.generate(145, (i) => (i + 1) % 256));

  bool throwOnSafetyNumber = false;

  @override
  Future<Uint8List> myDeviceId() async =>
      Uint8List.fromList(List.generate(16, (i) => i));

  @override
  Future<SafetyNumberDto> safetyNumber({required List<int> contactDeviceId}) async {
    if (throwOnSafetyNumber) {
      throw Exception('FfiError::Locked');
    }
    return const SafetyNumberDto(
      digits: '1234567890123456789012345678901234567890123456789012',
      words: 'apple banana cherry dog elephant fox grape horse igloo jaguar kite lion',
    );
  }

  @override
  Future<void> lock() async {
    lockCalls++;
  }

  @override
  Future<void> unlock() async {
    unlockCalls++;
  }

  @override
  Future<int> sweepExpiredMessages() async {
    sweepCalls++;
    return 0;
  }

  @override
  Future<List<MessageDto>> listMessages({required List<int> peerDeviceId}) async => [];

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async =>
      const SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
      );

  @override
  Future<SessionStatusDto?> sessionStatus({required List<int> peerDeviceId}) async =>
      const SessionStatusDto(
        state: SessionStateKind.handshaking,
        needsRehandshake: false,
      );

  @override
  Future<int> getEphemeralTtl({required List<int> contactDeviceId}) async => 0;

  @override
  Future<bool> isContactVerified({required List<int> contactDeviceId}) async => false;

  @override
  Future<bool> isKeyChanged({required List<int> contactDeviceId}) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockLocalAuth implements LocalAuthentication {
  _MockLocalAuth();

  bool shouldSucceed = true;
  int authCalls = 0;

  @override
  Future<bool> get canCheckBiometrics async => true;

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic>? authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authCalls++;
    return shouldSucceed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _MockSmokeCore core;
  late _MockLocalAuth localAuth;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('viska_smoke_test_');
    core = _MockSmokeCore();
    localAuth = _MockLocalAuth();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Mobile App Cold Start & Smoke Tests', () {
    testWidgets('MainApp renders PairingHomeScreen and profile header on startup', (
      WidgetTester tester,
    ) async {
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: core,
            router: P2PTransportRouter(core: core),
            lockController: controller,
            profileName: 'PerfilPrincipal',
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('Viska (PerfilPrincipal)'), findsOneWidget);
        expect(find.text('Luis Teste'), findsOneWidget);
        expect(find.text('Nenhum contato pareado ainda'), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets('MainApp displays contact list with verification badge and actions', (
      WidgetTester tester,
    ) async {
      final sampleContact = ContactDto(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        signingPubkey: Uint8List(32),
        dhPubkey: Uint8List(32),
        pairedAtUnixSecs: 1700000000,
        nickname: 'Alice Segura',
        isVerified: true,
      );

      final coreWithContacts = _MockSmokeCore(contacts: [sampleContact]);
      final controller = LockController(
        core: coreWithContacts,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: coreWithContacts,
            router: P2PTransportRouter(core: coreWithContacts),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('Alice Segura'), findsOneWidget);
        expect(find.byKey(const Key('verified_badge')), findsOneWidget);
        expect(find.byIcon(Icons.edit_outlined), findsWidgets);
        expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets(
        'MainApp tapping contact verifier opens SafetyNumberQrDialog and closes cleanly without freeze or crash', (
      WidgetTester tester,
    ) async {
      final sampleContact = ContactDto(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        signingPubkey: Uint8List(32),
        dhPubkey: Uint8List(32),
        pairedAtUnixSecs: 1700000000,
        nickname: 'Alice Segura',
        isVerified: true,
      );

      final coreWithContacts = _MockSmokeCore(contacts: [sampleContact]);
      final controller = LockController(
        core: coreWithContacts,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: coreWithContacts,
            router: P2PTransportRouter(core: coreWithContacts),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        final verifierButton = find.byIcon(Icons.verified_user_outlined);
        expect(verifierButton, findsOneWidget);

        // Tap the verifier button
        await tester.tap(verifierButton);
        await tester.pumpAndSettle();

        // SafetyNumberQrDialog is displayed with QR Code and numbers
        expect(find.text('Número de Segurança (Alice Segura)'), findsOneWidget);
        expect(find.byKey(const Key('scan_partner_qr_button')), findsOneWidget);
        expect(find.text('Fechar'), findsOneWidget);

        // Close dialog cleanly
        await tester.tap(find.text('Fechar'));
        await tester.pumpAndSettle();

        // Screen is still intact and responsive
        expect(find.text('Alice Segura'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets(
        'Tapping verifier when safetyNumber throws shows error SnackBar without crashing or freezing', (
      WidgetTester tester,
    ) async {
      final sampleContact = ContactDto(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        signingPubkey: Uint8List(32),
        dhPubkey: Uint8List(32),
        pairedAtUnixSecs: 1700000000,
        nickname: 'Alice Segura',
        isVerified: false,
      );

      final failingCore = _MockSmokeCore(contacts: [sampleContact])..throwOnSafetyNumber = true;
      final controller = LockController(
        core: failingCore,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: failingCore,
            router: P2PTransportRouter(core: failingCore),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        final verifierButton = find.byIcon(Icons.verified_user_outlined);
        await tester.tap(verifierButton);
        await tester.pumpAndSettle();

        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.textContaining('Aplicativo bloqueado'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets(
        'MainApp tapping contact opens ChatScreen cleanly without freeze or crash and navigates back', (
      WidgetTester tester,
    ) async {
      final sampleContact = ContactDto(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        signingPubkey: Uint8List(32),
        dhPubkey: Uint8List(32),
        pairedAtUnixSecs: 1700000000,
        nickname: 'Alice Conversa',
        isVerified: true,
      );

      final coreWithContacts = _MockSmokeCore(contacts: [sampleContact]);
      final controller = LockController(
        core: coreWithContacts,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: coreWithContacts,
            router: P2PTransportRouter(core: coreWithContacts),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        final contactTile = find.text('Alice Conversa');
        expect(contactTile, findsOneWidget);

        // Toca no contato para abrir a tela de conversa (ChatScreen)
        await tester.tap(contactTile);
        await tester.pumpAndSettle();

        // ChatScreen carregada com sucesso
        expect(find.text('Alice Conversa'), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.text('Nenhuma mensagem ainda'), findsOneWidget);

        // Volta para a tela inicial
        final backButton = find.byType(BackButton);
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pumpAndSettle();

        // Tela inicial íntegra
        expect(find.text('Alice Conversa'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets(
        'MainApp tapping contact when locked displays SnackBar warning without crashing', (
      WidgetTester tester,
    ) async {
      final sampleContact = ContactDto(
        deviceId: Uint8List.fromList(List.generate(16, (i) => i + 10)),
        signingPubkey: Uint8List(32),
        dhPubkey: Uint8List(32),
        pairedAtUnixSecs: 1700000000,
        nickname: 'Bob Bloqueado',
        isVerified: false,
      );

      final coreWithContacts = _MockSmokeCore(contacts: [sampleContact]);
      final controller = LockController(
        core: coreWithContacts,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: coreWithContacts,
            router: P2PTransportRouter(core: coreWithContacts),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        // Simula bloqueio do aplicativo
        controller.isLocked.value = true;

        // Tenta abrir o contato via chamada direta ou toque
        final contactTile = find.text('Bob Bloqueado');
        if (contactTile.evaluate().isNotEmpty) {
          await tester.tap(contactTile);
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.textContaining('Aplicativo bloqueado'), findsOneWidget);
        }

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets('MainApp navigates to SettingsScreen and returns cleanly', (
      WidgetTester tester,
    ) async {
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: core,
            router: P2PTransportRouter(core: core),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        final settingsButton = find.byTooltip('Configurações de Segurança');
        expect(settingsButton, findsOneWidget);

        await tester.tap(settingsButton);
        await tester.pumpAndSettle();

        expect(find.text('Configurações de Segurança'), findsOneWidget);

        final backButton = find.byType(BackButton);
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pumpAndSettle();

        expect(find.text('Viska'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets('MainApp navigates to PairingHubScreen and switches tabs cleanly', (
      WidgetTester tester,
    ) async {
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: core,
            router: P2PTransportRouter(core: core),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();

        final addContactButton = find.byType(FloatingActionButton);
        expect(addContactButton, findsOneWidget);

        await tester.tap(addContactButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Adicionar Contato'), findsOneWidget);
        expect(find.text('Proximidade'), findsOneWidget);
        expect(find.text('QR Code'), findsOneWidget);
        expect(find.text('Manual'), findsOneWidget);

        // Aba QR Code
        await tester.tap(find.text('QR Code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Aba Manual
        await tester.tap(find.text('Manual'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Copiar meu código Base64'), findsOneWidget);
        expect(find.text('Inserir código recebido'), findsOneWidget);

        // Volta para a tela inicial
        final backButton = find.byType(BackButton);
        expect(backButton, findsOneWidget);
        await tester.tap(backButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Viska'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });

    testWidgets('MainApp lifecycle: inactive keeps app unlocked, paused locks to LockScreen', (
      WidgetTester tester,
    ) async {
      final controller = LockController(
        core: core,
        appDirPath: tempDir.path,
        localAuth: localAuth,
        autoLockTimeout: null,
        autoLockOnBackground: true,
      );

      try {
        await tester.pumpWidget(
          MainApp(
            core: core,
            router: P2PTransportRouter(core: core),
            lockController: controller,
          ),
        );

        await tester.pumpAndSettle();
        expect(find.byType(LockScreen), findsNothing);

        // 1. Inactive: diálogo de permissão ou biometria. App deve continuar destrancado.
        controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
        await tester.pump();

        expect(controller.isLocked.value, isFalse);
        expect(find.byType(LockScreen), findsNothing);
        // 2. Paused: aplicativo minimizado. App deve trancar.
        // Desativa o auto-sucesso imediato para poder inspecionar a LockScreen
        localAuth.shouldSucceed = false;
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump(); // conclui a Promise assíncrona de lock()
        await tester.pump(); // renderiza o novo frame com LockScreen

        expect(controller.isLocked.value, isTrue);
        expect(find.byType(LockScreen), findsOneWidget);

        // 3. Unlock: usuário autentica e retorna à tela normal
        localAuth.shouldSucceed = true;
        await controller.unlock();
        await tester.pump(); // conclui unlock()
        await tester.pump(); // renderiza retorno à PairingHomeScreen

        expect(controller.isLocked.value, isFalse);
        expect(find.byType(LockScreen), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        controller.dispose();
      }
    });
  });
}
