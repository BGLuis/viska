import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:viska/src/features/lock/security_channel.dart';
import 'package:viska/src/rust/ffi/core.dart';

/// Controlador do estado de bloqueio e segurança em repouso (Fase 7, F1/F2/F3).
///
/// Responsabilidades:
/// 1. Monitora o ciclo de vida do aplicativo (`AppLifecycleState`) e eventos de
///    inatividade do usuário para bloquear o aplicativo automaticamente.
/// 2. Ao bloquear, comanda o fechamento das sessões ativas e a destruição de
///    chaves em memória no Rust (`core.lock()`).
/// 3. Ao desbloquear, exige autenticação biométrica ou PIN do dispositivo via
///    `local_auth`, solicita a injeção nativa da chave pelo Android KeyStore
///    (sem trafegar bytes no Dart) e reabre o banco (`core.unlock()`).
/// 4. Executa varreduras periódicas de expiração de mensagens efêmeras (F3)
///    enquanto desbloqueado.
class LockController with WidgetsBindingObserver {
  LockController({
    required this.core,
    required this.appDirPath,
    LocalAuthentication? localAuth,
    this.autoLockTimeout = const Duration(minutes: 1),
    this.autoLockOnBackground = true,
  }) : _localAuth = localAuth ?? LocalAuthentication() {
    WidgetsBinding.instance.addObserver(this);
    _resetInactivityTimer();
    _startEphemeralSweepTimer();
  }

  final Core core;
  final String appDirPath;
  final LocalAuthentication _localAuth;

  /// Notificador reativo do estado de bloqueio da aplicação.
  final ValueNotifier<bool> isLocked = ValueNotifier<bool>(false);

  /// Tempo de inatividade do usuário antes do bloqueio automático.
  /// Se nulo, o bloqueio por inatividade fica desativado.
  Duration? autoLockTimeout;

  /// Se verdadeiro, bloqueia imediatamente ao mover o app para segundo plano.
  bool autoLockOnBackground;

  Timer? _inactivityTimer;
  Timer? _ephemeralSweepTimer;

  String get _encryptedMasterKeyPath => '$appDirPath/master_wrapped.bin';

  /// Notifica interação do usuário para postergar o bloqueio por inatividade.
  void onUserInteraction() {
    if (isLocked.value) return;
    _resetInactivityTimer();
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    final timeout = autoLockTimeout;
    if (timeout != null && timeout > Duration.zero) {
      _inactivityTimer = Timer(timeout, () {
        lock();
      });
    }
  }

  void _startEphemeralSweepTimer() {
    _ephemeralSweepTimer?.cancel();
    // Executa varredura a cada 60 segundos enquanto o app estiver desbloqueado
    _ephemeralSweepTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!isLocked.value) {
        try {
          await core.sweepExpiredMessages();
        } catch (_) {
          // Ignora falhas pontuais de varredura periódica
        }
      }
    });
  }

  /// Bloqueia o aplicativo imediatamente:
  /// - Zera e descarta sessões ativas do Rust.
  /// - Fecha a conexão com o banco SQLite.
  /// - Limpa a chave mestra da memória de processo.
  Future<void> lock() async {
    if (isLocked.value) return;
    _inactivityTimer?.cancel();

    try {
      await core.lock();
    } catch (_) {
      // Falha ao travar o core não impede que a UI mostre a tela de bloqueio
    }

    isLocked.value = true;
  }

  /// Desbloqueia o aplicativo mediante autenticação biométrica / credencial do SO.
  ///
  /// Retorna `true` se autenticado com sucesso e o cofre foi aberto, ou `false` se cancelado/falhou.
  Future<bool> unlock() async {
    try {
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (canCheckBiometrics || isDeviceSupported) {
        final authenticated = await _localAuth.authenticate(
          localizedReason: 'Autentique-se para desbloquear o Viska',
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: false,
          ),
        );
        if (!authenticated) return false;
      }
    } on PlatformException {
      // Em ambientes sem suporte ou com falha de sensor
      return false;
    } catch (_) {
      return false;
    }

    // No Android, desfralda a chave mestra via KeyStore diretamente para o Rust
    if (Platform.isAndroid) {
      await SecurityChannel.initMasterSecret(_encryptedMasterKeyPath);
    }

    // Comanda o core Rust a reabrir o cofre e restaurar estado
    try {
      await core.unlock();
    } catch (e) {
      // Se falhar reabertura do cofre, mantém bloqueado
      return false;
    }

    isLocked.value = false;
    _resetInactivityTimer();

    // Varre mensagens que expiraram durante o período bloqueado
    try {
      await core.sweepExpiredMessages();
    } catch (_) {}

    return true;
  }

  /// Apagamento de emergência (Fase 7, F2):
  /// - Destrói a chave mestra no hardware/KeyStore e zera no Rust.
  /// - Deleta o banco de dados e arquivos de staging no disco.
  /// - Trava o app.
  Future<void> emergencyErase() async {
    _inactivityTimer?.cancel();
    _ephemeralSweepTimer?.cancel();

    // 1. Zera banco e segredos via Rust Core
    try {
      await core.emergencyErase();
    } catch (_) {}

    // 2. Destrói chave no Android KeyStore e arquivo cifrado
    if (Platform.isAndroid) {
      await SecurityChannel.destroyMasterSecret(_encryptedMasterKeyPath);
    }

    // 3. Trava o estado
    isLocked.value = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (autoLockOnBackground) {
        lock();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!isLocked.value) {
        _resetInactivityTimer();
        core.sweepExpiredMessages().catchError((_) => 0);
      }
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inactivityTimer?.cancel();
    _ephemeralSweepTimer?.cancel();
    isLocked.dispose();
  }
}
