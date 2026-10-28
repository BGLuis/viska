import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
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
    DateTime Function()? clock,
  })  : _localAuth = localAuth ?? LocalAuthentication(),
        _clock = clock ?? DateTime.now {
    instance = this;
    WidgetsBinding.instance.addObserver(this);
    _resetInactivityTimer();
    _startEphemeralSweepTimer();
    _loadSecurityConfig();
  }

  /// Instância singleton ativa para facilitação de guards de ciclo de vida.
  static LockController? instance;

  /// Executa uma ação de plataforma transiente (como permissões de câmera ou biometria)
  /// impedindo que transições temporárias para `paused` bloqueiem indevidamente o app.
  static Future<T> guardTransient<T>(Future<T> Function() action) async {
    final active = instance;
    if (active != null) {
      return active.runWithTransientGuard(action);
    }
    return action();
  }

  final Core core;
  final String appDirPath;
  final LocalAuthentication _localAuth;
  final DateTime Function() _clock;

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
  int? _normalPinLength;
  int? _duressPinLength;

  int _failedPinAttempts = 0;
  DateTime? _pinRetryNotBefore;

  static const int minPinLength = 4;
  static const int maxPinLength = 8;

  /// Tentativas livres antes de começar a espera progressiva entre tentativas.
  static const int freePinAttempts = 5;

  static const Duration _baseRetryDelay = Duration(seconds: 30);
  static const Duration _maxRetryDelay = Duration(minutes: 15);

  /// Quantidade de dígitos do PIN Normal configurado (ou nulo se não definido).
  int? get normalPinLength => _normalPinLength;

  /// Quantidade de dígitos do PIN de Coação configurado (ou nulo se não definido).
  int? get duressPinLength => _duressPinLength;

  Timer? _inactivityTimer;
  Timer? _ephemeralSweepTimer;

  int _transientOperationsCount = 0;

  /// Indica se uma operação de plataforma transiente (diálogo de permissão, prompt de biometria) está em andamento.
  bool get isTransientOperationActive => _transientOperationsCount > 0;

  void beginTransientOperation() {
    _transientOperationsCount++;
  }

  void endTransientOperation() {
    if (_transientOperationsCount > 0) {
      _transientOperationsCount--;
    }
  }

  Future<T> runWithTransientGuard<T>(Future<T> Function() action) async {
    beginTransientOperation();
    try {
      return await action();
    } finally {
      endTransientOperation();
    }
  }

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
        _normalPinLength = (json['normal_pin_length'] as num?)?.toInt();
        _duressPinLength = (json['duress_pin_length'] as num?)?.toInt();
        duressActionMode = (json['duress_action_mode'] as num?)?.toInt() ?? 0;
        _failedPinAttempts = (json['failed_pin_attempts'] as num?)?.toInt() ?? 0;
        final notBefore = (json['pin_retry_not_before_ms'] as num?)?.toInt();
        _pinRetryNotBefore =
            notBefore == null ? null : DateTime.fromMillisecondsSinceEpoch(notBefore);
      }
    } catch (_) {}
  }

  Future<void> _saveSecurityConfig() async {
    try {
      final file = File(_securityConfigPath);
      final json = {
        if (_normalPinHash != null) 'normal_pin_hash': _normalPinHash,
        if (_duressPinHash != null) 'duress_pin_hash': _duressPinHash,
        if (_normalPinLength != null) 'normal_pin_length': _normalPinLength,
        if (_duressPinLength != null) 'duress_pin_length': _duressPinLength,
        'duress_action_mode': duressActionMode,
        if (_failedPinAttempts > 0) 'failed_pin_attempts': _failedPinAttempts,
        if (_pinRetryNotBefore != null)
          'pin_retry_not_before_ms': _pinRetryNotBefore!.millisecondsSinceEpoch,
      };
      file.writeAsStringSync(jsonEncode(json));
    } catch (_) {}
  }

  /// Configura o PIN normal do aplicativo. `null` ou vazio remove os dois PINs,
  /// porque um PIN de Coação sem PIN Normal não tem o que imitar.
  Future<void> setNormalPin(String? pin) async {
    if (pin == null || pin.trim().isEmpty) {
      await clearPins();
      return;
    }
    await configurePins(normalPin: pin);
  }

  /// Configura o PIN de Coação e o modo de ação de defesa física.
  Future<void> setDuressPin(String? pin, {int actionMode = 0}) async {
    if (pin == null || pin.trim().isEmpty) {
      _duressPinHash = null;
      _duressPinLength = null;
      duressActionMode = actionMode;
      await _saveSecurityConfig();
      return;
    }
    await configurePins(duressPin: pin, actionMode: actionMode);
  }

  /// Aplica a configuração de PINs de uma vez, validando o estado resultante
  /// como um todo. Argumento `null` mantém o valor atual.
  ///
  /// Lança [PinConfigException] sem alterar nada quando a combinação é inválida.
  Future<void> configurePins({
    String? normalPin,
    String? duressPin,
    int? actionMode,
  }) async {
    final normal = normalPin == null ? null : _validatedPin(normalPin);
    final duress = duressPin == null ? null : _validatedPin(duressPin);

    final nextNormalHash = normal == null ? _normalPinHash : _hashPin(normal);
    final nextNormalLength = normal == null ? _normalPinLength : normal.length;
    final nextDuressHash = duress == null ? _duressPinHash : _hashPin(duress);
    final nextDuressLength = duress == null ? _duressPinLength : duress.length;

    if (nextDuressHash != null) {
      if (nextNormalHash == null) {
        throw const PinConfigException('Configure primeiro o PIN Normal.');
      }
      // Coação igual ao Normal faria o próprio PIN do dono disparar a defesa
      // (a coação é testada primeiro no desbloqueio).
      if (nextDuressHash == nextNormalHash) {
        throw const PinConfigException(
          'O PIN de Coação não pode ser igual ao PIN Normal.',
        );
      }
      // A tela de bloqueio envia o PIN sozinha ao atingir o tamanho esperado;
      // com tamanhos diferentes o mais longo nunca chegaria a ser digitado, e
      // a quantidade de pontos denunciaria qual dos dois está sendo usado.
      if (nextDuressLength != nextNormalLength) {
        throw const PinConfigException(
          'O PIN de Coação precisa ter a mesma quantidade de dígitos do PIN Normal.',
        );
      }
    }

    _normalPinHash = nextNormalHash;
    _normalPinLength = nextNormalLength;
    _duressPinHash = nextDuressHash;
    _duressPinLength = nextDuressLength;
    if (actionMode != null) duressActionMode = actionMode;
    await _saveSecurityConfig();
  }

  /// Remove o PIN Normal e o de Coação.
  Future<void> clearPins() async {
    _normalPinHash = null;
    _normalPinLength = null;
    _duressPinHash = null;
    _duressPinLength = null;
    _failedPinAttempts = 0;
    _pinRetryNotBefore = null;
    await _saveSecurityConfig();
  }

  static String _validatedPin(String pin) {
    final trimmed = pin.trim();
    if (!RegExp('^[0-9]{$minPinLength,$maxPinLength}\$').hasMatch(trimmed)) {
      throw const PinConfigException(
        'O PIN deve ter de $minPinLength a $maxPinLength dígitos, só números.',
      );
    }
    return trimmed;
  }

  /// Tempo que ainda falta até a próxima tentativa de PIN ser aceita.
  Duration get pinRetryDelay {
    final notBefore = _pinRetryNotBefore;
    if (notBefore == null) return Duration.zero;
    final remaining = notBefore.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Verdadeiro quando [pin] coincide com algum PIN configurado. A tela de
  /// bloqueio usa isso para não enviar cedo um PIN mais curto que o outro em
  /// configurações antigas, gravadas antes de os tamanhos serem igualados.
  bool matchesAnyPin(String pin) => isNormalPin(pin) || isDuressPin(pin);

  Future<void> _registerFailedPinAttempt() async {
    _failedPinAttempts++;
    final excess = _failedPinAttempts - freePinAttempts;
    if (excess >= 0) {
      final factor = 1 << (excess > 10 ? 10 : excess);
      final delay = _baseRetryDelay * factor;
      _pinRetryNotBefore =
          _clock().add(delay > _maxRetryDelay ? _maxRetryDelay : delay);
    }
    await _saveSecurityConfig();
  }

  Future<void> _resetFailedPinAttempts() async {
    if (_failedPinAttempts == 0 && _pinRetryNotBefore == null) return;
    _failedPinAttempts = 0;
    _pinRetryNotBefore = null;
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
        final authenticated = await runWithTransientGuard(
          () => _localAuth.authenticate(
            localizedReason: 'Autentique-se para desbloquear o Viska',
            options: const AuthenticationOptions(
              stickyAuth: true,
              biometricOnly: false,
            ),
          ),
        );
        if (!authenticated) return false;
        biometricPassed = true;
      }
    } on MissingPluginException {
      // Plataforma sem implementação do local_auth (o alvo Linux de
      // desenvolvimento): equivale a um aparelho sem autenticação do sistema,
      // e segue a mesma regra abaixo — sem PIN desbloqueia, com PIN exige o PIN.
      // Tratar como falha deixaria o app preso na tela de bloqueio para sempre.
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
    // Durante a espera nenhum PIN é avaliado, nem o de Coação: aceitar só ele
    // revelaria a quem observa que aquele PIN é especial.
    if (pinRetryDelay > Duration.zero) return false;

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
        await _resetFailedPinAttempts();
        await activateDecoyVault();
        return true;
      }
    }

    if (isNormalPin(trimmed)) {
      final unlocked = await _unlockWithoutBiometrics();
      if (unlocked) await _resetFailedPinAttempts();
      return unlocked;
    }

    await _registerFailedPinAttempt();
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

    // Arquivos recebidos em claro sob o diretório de dados ou resíduos de
    // transferências precisam ser destruídos no apagamento de emergência para
    // que nenhum plaintext sem dono sobreviva (S-08).
    try {
      final receivedDir = Directory('$appDirPath/received');
      if (receivedDir.existsSync()) receivedDir.deleteSync(recursive: true);
    } catch (_) {}

    try {
      final appDir = Directory(appDirPath);
      if (appDir.existsSync()) {
        for (final entity in appDir.listSync(recursive: true)) {
          if (entity is File && p.basename(entity.path).startsWith('viska-recv-')) {
            entity.deleteSync();
          }
        }
      }
    } catch (_) {}

    try {
      final tempDir = Directory.systemTemp;
      for (final entity in tempDir.listSync()) {
        if (entity is File && p.basename(entity.path).startsWith('viska-recv-')) {
          entity.deleteSync();
        }
      }
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
    // Apenas paused (app em segundo plano) ou detached devem trancar o app.
    // 'inactive' é um estado transitório disparado durante diálogos de permissão
    // do sistema (câmera, microfone), biometria ou painel de notificações.
    // Trancar em 'inactive' fecharia o banco enquanto o usuário ainda está interagindo.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (isTransientOperationActive) {
        // Ignora transições 'paused' disparadas por diálogos nativos do sistema
        // (como solicitações de permissão de câmera, microfone ou prompts biométricos).
        return;
      }
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
    if (identical(instance, this)) {
      instance = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _inactivityTimer?.cancel();
    _ephemeralSweepTimer?.cancel();
    isLocked.dispose();
    isDecoyVault.dispose();
  }
}

/// PIN recusado na configuração; [message] já é o texto para o usuário.
class PinConfigException implements Exception {
  const PinConfigException(this.message);

  final String message;

  @override
  String toString() => 'PinConfigException: $message';
}
