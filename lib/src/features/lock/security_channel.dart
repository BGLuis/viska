import 'dart:io';
import 'package:flutter/services.dart';

/// Comunicação com o canal de plataforma de segurança nativo (`app.viska/security`).
///
/// Implementa a ponte com o Android KeyStore (StrongBox/TEE) e controle dinâmico
/// de `FLAG_SECURE` (Fase 7, F0/F1/F2).
///
/// Regra inegociável: nenhum material de chave trafega por este canal ou entra no
/// heap Dart. O canal apenas orquestra ações de hardware que entregam o segredo
/// diretamente aos buffers protegidos do Rust via JNI ou limpam o enclave.
class SecurityChannel {
  SecurityChannel._();

  static const _channel = MethodChannel('app.viska/security');

  /// Ativa ou desativa `FLAG_SECURE` na janela nativa (Android).
  ///
  /// Impede screenshots, gravação de tela e captura de miniatura no alternador
  /// de tarefas do sistema operacional.
  static Future<void> setFlagSecure(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setFlagSecure', {'enabled': enabled});
    } on MissingPluginException {
      // Ignora silenciosamente em testes ou plataformas sem o canal nativo.
    } catch (_) {
      // Falha não-bloqueante na manipulação de flags da janela.
    }
  }

  /// Consulta se `FLAG_SECURE` está ativo na janela nativa.
  static Future<bool> isFlagSecure() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isFlagSecure');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Solicita ao KeyStore nativo que desfralde a chave mestra em memória e a
  /// transfira diretamente para a camada Rust via JNI.
  ///
  /// O parâmetro [encryptedMasterKeyPath] aponta para o arquivo que armazena
  /// o IV + ciphertext encriptados pelo KeyStore.
  static Future<bool> initMasterSecret(String encryptedMasterKeyPath) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('initMasterSecret', {
        'path': encryptedMasterKeyPath,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Destrói a chave no KeyStore de hardware, apaga o arquivo cifrado e zera
  /// o material na memória Rust nativa (crypto-shredding).
  static Future<bool> destroyMasterSecret(String encryptedMasterKeyPath) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('destroyMasterSecret', {
        'path': encryptedMasterKeyPath,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
