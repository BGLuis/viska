import 'package:viska/src/rust/ffi/pin.dart' as ffi;

export 'package:viska/src/rust/ffi/pin.dart' show PinCheckDto, PinMatchDto;

/// Derivação e verificação dos PINs de desbloqueio.
///
/// Existe como interface para que os testes do `LockController` não dependam
/// da biblioteca Rust carregada (eles usam um `Core` falso pelo mesmo motivo).
/// Em produção a derivação é Argon2id no Rust (issue #90): o PIN cruza o FFI
/// só no sentido Dart→Rust, por decisão explícita do mantenedor.
abstract interface class PinHasher {
  /// String PHC com sal aleatório novo; pode ser gravada em claro.
  Future<String> hash(String pin);

  /// Confere [pin] contra os dois hashes gravados com o mesmo trabalho seja
  /// qual for o PIN, para que o tempo não denuncie o PIN de coação.
  Future<ffi.PinCheckDto> check(
    String pin, {
    String? normalHash,
    String? duressHash,
  });
}

class RustPinHasher implements PinHasher {
  const RustPinHasher();

  @override
  Future<String> hash(String pin) => ffi.pinHash(pin: pin);

  @override
  Future<ffi.PinCheckDto> check(
    String pin, {
    String? normalHash,
    String? duressHash,
  }) =>
      ffi.pinCheck(pin: pin, normalHash: normalHash, duressHash: duressHash);
}

/// Verdadeiro se [storedHash] ainda está no formato legado (SHA-256 hex sem
/// sal nem custo). Espelha `is_legacy_hash` do Rust; fica no Dart, e não no
/// FFI, porque a tela de Ajustes precisa da resposta de forma síncrona e o
/// valor examinado é o mesmo que está em claro no `security_config.json`.
bool isLegacyPinHash(String storedHash) => _legacyPinHash.hasMatch(storedHash);

final _legacyPinHash = RegExp(r'^[0-9a-fA-F]{64}$');
