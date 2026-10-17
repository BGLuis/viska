import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/features/home/home_screen.dart';
import 'package:viska/src/features/lock/inactivity_detector.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/frb_generated.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';
import 'package:viska/src/transport/message_reception_service.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';

export 'package:viska/src/features/home/home_screen.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Barreira defensiva contra exceções assíncronas não capturadas (MethodChannels, Streams, Sockets).
  // Retornar true confirma o tratamento e impede que a máquina virtual encerre o processo do app.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) debugPrint('[Viska CrashBarrier] Erro assíncrono interceptado: $error');
    return true;
  };

  // Intercepta erros de framework do Flutter de forma graciosa sem vazar material de chave.
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  // Substitui a tela vermelha/amarela padrão do Flutter por um contêiner escuro seguro e contido.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: ViskaColors.bgCanvas,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 48, color: ViskaColors.ephemeralDefault),
              const SizedBox(height: 16),
              const Text(
                'Falha temporária de interface',
                style: TextStyle(
                  color: ViskaColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                kDebugMode ? details.exceptionAsString() : 'Ocorreu um erro transitório na renderização deste elemento.',
                style: const TextStyle(
                  color: ViskaColors.textSecondary,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  };

  await RustLib.init();

  String? profile;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--profile' && i + 1 < args.length) {
      profile = args[i + 1];
      break;
    }
  }
  profile ??= Platform.environment['VISKA_PROFILE'];

  final baseDir = await getApplicationSupportDirectory();
  final appDir = profile != null
      ? Directory('${baseDir.path}/profiles/$profile')
      : baseDir;
  if (!await appDir.exists()) {
    await appDir.create(recursive: true);
  }

  final core = await Core.open(appDir: appDir.path);
  // Um único router para o app inteiro: ele cria (e conecta) um transporte
  // por contato sob demanda — Fase 3, F5.
  final router = P2PTransportRouter(core: core);
  final receptionService = MessageReceptionService(
    core: core,
    router: router,
    appDirPath: appDir.path,
  );
  await receptionService.start();

  final lockController = LockController(
    core: core,
    appDirPath: appDir.path,
  );

  lockController.isLocked.addListener(() {
    if (lockController.isLocked.value) {
      receptionService.pause();
    } else {
      receptionService.resume();
    }
  });

  runApp(MainApp(
    core: core,
    router: router,
    receptionService: receptionService,
    lockController: lockController,
    profileName: profile,
  ));
}

class MainApp extends StatelessWidget {
  const MainApp({
    super.key,
    required this.core,
    required this.router,
    required this.lockController,
    this.receptionService,
    this.profileName,
  });

  final Core core;
  final P2PTransportRouter router;
  final LockController lockController;
  final MessageReceptionService? receptionService;
  final String? profileName;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: profileName != null ? 'Viska ($profileName)' : 'Viska',
      theme: DarkTechTheme.theme,
      home: AnimatedBuilder(
        animation: Listenable.merge([lockController.isLocked, lockController.isDecoyVault]),
        builder: (context, _) {
          if (lockController.isLocked.value) {
            return InactivityDetector(
              controller: lockController,
              child: LockScreen(controller: lockController),
            );
          }

          final currentCore = lockController.activeCore;
          final currentRouter = currentCore == core ? router : P2PTransportRouter(core: currentCore);
          final currentReception = currentCore == core ? receptionService : null;

          return InactivityDetector(
            controller: lockController,
            child: HomeScreen(
              key: ValueKey(currentCore),
              core: currentCore,
              router: currentRouter,
              receptionService: currentReception,
              lockController: lockController,
              profileName: profileName,
            ),
          );
        },
      ),
    );
  }
}
