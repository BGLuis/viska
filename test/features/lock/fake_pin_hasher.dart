import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:viska/src/features/lock/pin_hasher.dart';

/// Hasher sem a biblioteca Rust, para os testes de interface do bloqueio.
///
/// Reproduz o contrato do Argon2id real que importa para o `LockController`:
/// cada `hash` sai diferente mesmo com o mesmo PIN (sal por hash), o formato
/// legado SHA-256 é aceito e pede regravação, e a coação prevalece. O KDF de
/// verdade é testado em `rust/logic/src/crypto/pin.rs`.
class FakePinHasher implements PinHasher {
  static var _salt = 0;
  var hashCalls = 0;
  var checkCalls = 0;
  var throwOnCheck = false;
  var throwOnHash = false;

  /// Quando definido, toda verificação espera por ele: simula a derivação
  /// lenta do aparelho real para testar o que a interface faz enquanto isso.
  Completer<void>? checkGate;

  static String legacyHash(String pin) =>
      sha256.convert(utf8.encode('viska-pin-v1:$pin')).toString();

  @override
  Future<String> hash(String pin) async {
    hashCalls++;
    if (throwOnHash) throw StateError('falha na derivação');
    return 'fake\$${_salt++}\$$pin';
  }

  @override
  Future<PinCheckDto> check(
    String pin, {
    String? normalHash,
    String? duressHash,
  }) async {
    checkCalls++;
    if (throwOnCheck) throw StateError('falha na derivação');
    final gate = checkGate;
    if (gate != null) await gate.future;
    final duress = _verify(pin, duressHash);
    if (duress != null) {
      return PinCheckDto(matched: PinMatchDto.duress, needsRehash: duress);
    }
    final normal = _verify(pin, normalHash);
    if (normal != null) {
      return PinCheckDto(matched: PinMatchDto.normal, needsRehash: normal);
    }
    return const PinCheckDto(matched: PinMatchDto.noMatch, needsRehash: false);
  }

  /// `null` quando não coincide; senão, se precisa regravar.
  bool? _verify(String pin, String? stored) {
    if (stored == null) return null;
    if (isLegacyPinHash(stored)) return stored == legacyHash(pin) ? true : null;
    final parts = stored.split('\$');
    if (parts.length == 3 && parts[0] == 'fake' && parts[2] == pin) return false;
    return null;
  }
}
