import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:viska/src/features/lock/security_channel.dart';
import 'package:viska/src/rust/ffi/core.dart';

/// Controlador do estado de bloqueio, segurança em repouso e defesa física contra coerção.
///
/// Responsabilidades:
/// 1. Monitora o ciclo de vida do aplicativo (`AppLifecycleState`) e eventos de
///    inatividade do usuário para bloquear o aplicativo automaticamente.
/// 2. Ao bloquear, comanda o fechamento das sessões ativas e a destruição de
///    chaves em memória no Rust (`core.lock()`).
/// 3. Ao desbloquear, suporta autenticação biométrica via `local_auth` ou validação de PIN.
/// 4. Defesa Física: Valida PIN de Coação (Duress PIN):
///    - Se `actionMode == 0` (Destruição Silenciosa): `core.emergencyErase()` imediato e encerramento simulado do app.
///    - Se `actionMode == 1` (Cofre Falso / Decoy Vault): chaveia para o cofre inócuo isolado.
/// 5. Executa varreduras periódicas de expiração de mensagens efêmeras enquanto desbloqueado.
class LockController with WidgetsBindingObserver {
  LockController({
    required this.core,
    required this.appDirPath,
    LocalAuthentication? localAuth,
    this.autoLockTimeout = const Duration(minutes: 1),
    this.autoLockOnBackground = true,
    this.exitFn,
  }) : _localAuth = localAuth ?? LocalAuthentication() {
    WidgetsBinding.instance.addObserver(this);
    _resetInactivityTimer();
    _startEphemeralSweepTimer();
    _loadSecurityConfig();
  }

  final Core core;
  final String appDirPath;
  final LocalAuthentication _localAuth;

  /// Hook para simulação/interceptação de encerramento do processo em testes.
  void Function(int code)? exitFn;

  /// Notificador reativo do estado de bloqueio da aplicação.
  final ValueNotifier<bool> isLocked = ValueNotifier<bool>(false);

  /// Notificador se o cofre falso (Decoy Vault) está ativo.
  final ValueNotifier<bool> isDecoyVault = ValueNotifier<bool>(false);

  /// Devolve a instância ativa da Core: a legítima ou a falsa isolada.
  Core get activeCore => (isDecoyVault.value && _decoyCore != null) ? _decoyCore! : core;

  Core? _decoyCore;

  /// Tempo de inatividade do usuário antes do bloqueio automático.
  /// Se nulo, o bloqueio por inatividade fica desativado.
  Duration? autoLockTimeout;

  /// Se verdadeiro, bloqueia imediatamente ao mover o app para segundo plano.
  bool autoLockOnBackground;

  /// Modo de ação do PIN de coação:
  /// 0 = Destruição Silenciosa (`emergencyErase()` + exit(0))
  /// 1 = Cofre Falso / Decoy Vault (`activateDecoyVault()`)
  int duressActionMode = 0;

  String? _normalPinHash;
  String? _duressPinHash;

  Timer? _inactivityTimer;
  Timer? _ephemeralSweepTimer;

  String get _encryptedMasterKeyPath => '$appDirPath/master_wrapped.bin';
  String get _securityConfigPath => '$appDirPath/security_config.json';

  bool get hasNormalPin => _normalPinHash != null;
  bool get hasDuressPin => _duressPinHash != null;

  static String _hashPin(String pin) {
    return sha256.convert(utf8.encode('viska-pin-v1:$pin')).toString();
  }

  bool isNormalPin(String pin) {
    if (_normalPinHash == null) return false;
    return _normalPinHash == _hashPin(pin);
  }

  bool isDuressPin(String pin) {
    if (_duressPinHash == null) return false;
    return _duressPinHash == _hashPin(pin);
  }

  Future<void> _loadSecurityConfig() async {
    try {
      final file = File(_securityConfigPath);
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _normalPinHash = json['normal_pin_hash'] as String?;
        _duressPinHash = json['duress_pin_hash'] as String?;
        duressActionMode = (json['duress_action_mode'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
  }

  Future<void> _saveSecurityConfig() async {
    try {
      final file = File(_securityConfigPath);
      final json = {
        if (_normalPinHash != null) 'normal_pin_hash': _normalPinHash,
        if (_duressPinHash != null) 'duress_pin_hash': _duressPinHash,
        'duress_action_mode': duressActionMode,
      };
      file.writeAsStringSync(jsonEncode(json));
    } catch (_) {}
  }

  /// Configura o PIN normal do aplicativo.
  Future<void> setNormalPin(String? pin) async {
    if (pin == null || pin.trim().isEmpty) {
      _normalPinHash = null;
    } else {
      _normalPinHash = _hashPin(pin.trim());
    }
    await _saveSecurityConfig();
  }

  /// Configura o PIN de Coação e o modo de ação de defesa física.
  Future<void> setDuressPin(String? pin, {int actionMode = 0}) async {
    if (pin == null || pin.trim().isEmpty) {
      _duressPinHash = null;
    } else {
      _duressPinHash = _hashPin(pin.trim());
    }
    duressActionMode = actionMode;
    await _saveSecurityConfig();
  }

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
    _ephemeralSweepTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!isLocked.value && !isDecoyVault.value) {
        try {
          await core.sweepExpiredMessages();
        } catch (_) {}
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

    if (isDecoyVault.value) {
      try {
        await _decoyCore?.lock();
      } catch (_) {}
      isDecoyVault.value = false;
    }

    try {
      await core.lock();
    } catch (_) {}

    isLocked.value = true;
  }

  /// Desbloqueia o aplicativo mediante autenticação biométrica / credencial do SO.
  Future<bool> unlock() async {
    var biometricPassed = false;
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
        biometricPassed = true;
      }
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }

    // Se possui PIN configurado e a biometria não foi autenticada,
    // não deve desbloquear sem digitação do PIN.
    if (hasNormalPin && !biometricPassed) {
      return false;
    }

    return await _unlockWithoutBiometrics();
  }

  /// Valida o PIN inserido e executa o fluxo apropriado:
  /// - PIN de Coação (Destruição Silenciosa ou Decoy Vault)
  /// - PIN Normal (Desbloqueio Legítimo)
  Future<bool> verifyAndUnlockWithPin(String pin) async {
    final trimmed = pin.trim();

    if (isDuressPin(trimmed)) {
      if (duressActionMode == 0) {
        // Destruição Silenciosa: crypto-shredding imediato e término inesperado
        await emergencyErase();
        if (exitFn != null) {
          exitFn!(0);
        } else {
          exit(0);
        }
        return false;
      } else {
        // Modo 2: Alterna para o cofre falso (Decoy Vault)
        await activateDecoyVault();
        return true;
      }
    }

    if (isNormalPin(trimmed)) {
      return await _unlockWithoutBiometrics();
    }

    return false;
  }

  /// Ativa o cofre falso com histórico inócuo.
  Future<void> activateDecoyVault() async {
    _inactivityTimer?.cancel();
    final decoyDir = '$appDirPath/decoy';
    final dir = Directory(decoyDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    try {
      _decoyCore ??= await Core.open(appDir: decoyDir);
      final currentNick = await _decoyCore!.myNickname();
      if (currentNick == null || currentNick.trim().isEmpty) {
        await _decoyCore!.setMyNickname(nickname: 'Visitante');
      }
    } catch (_) {}

    isDecoyVault.value = true;
    isLocked.value = false;
    _resetInactivityTimer();
  }

  Future<bool> _unlockWithoutBiometrics() async {
    // No Android, desfralda a chave mestra via KeyStore diretamente para o Rust
    if (Platform.isAndroid) {
      await SecurityChannel.initMasterSecret(_encryptedMasterKeyPath);
    }

    // Comanda o core Rust a reabrir o cofre e restaurar estado
    try {
      await core.unlock();
    } catch (e) {
      return false;
    }

    isLocked.value = false;
    isDecoyVault.value = false;
    _resetInactivityTimer();

    try {
      await core.sweepExpiredMessages();
    } catch (_) {}

    return true;
  }

  /// Apagamento de emergência (Fase 7, F2):
  /// - Destrói a chave mestra no hardware/KeyStore e zera no Rust.
  /// - Deleta o banco de dados e arquivos de staging no disco.
  /// - Destrói cofre decoy e configurações locais.
  /// - Trava o app.
  Future<void> emergencyErase() async {
    _inactivityTimer?.cancel();
    _ephemeralSweepTimer?.cancel();

    _normalPinHash = null;
    _duressPinHash = null;

    try {
      final secFile = File(_securityConfigPath);
      if (secFile.existsSync()) secFile.deleteSync();
    } catch (_) {}

    // 1. Zera banco e segredos via Rust Core
    try {
      await core.emergencyErase();
    } catch (_) {}

    if (_decoyCore != null) {
      try {
        await _decoyCore!.emergencyErase();
      } catch (_) {}
    }

    try {
      final decoyDir = Directory('$appDirPath/decoy');
      if (decoyDir.existsSync()) decoyDir.deleteSync(recursive: true);
    } catch (_) {}

    // 2. Destrói chave no Android KeyStore e arquivo cifrado
    if (Platform.isAndroid) {
      await SecurityChannel.destroyMasterSecret(_encryptedMasterKeyPath);
    }

    // 3. Trava o estado
    isDecoyVault.value = false;
    isLocked.value = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (autoLockOnBackground) {
        lock();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!isLocked.value && !isDecoyVault.value) {
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
    isDecoyVault.dispose();
  }
}
