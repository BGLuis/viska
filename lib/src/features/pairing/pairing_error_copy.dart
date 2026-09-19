import 'package:viska/src/rust/ffi/error.dart';

/// Mensagem em PT-BR para cada variante de [FfiError].
///
/// Cada variante tem texto próprio de propósito — em especial [FfiError.forgedKey],
/// que sinaliza um QR forjado (chave X25519 de ordem baixa) e merece um tom de
/// alerta de segurança, não a mesma mensagem genérica de "não consegui ler".
/// Ver armadilha 4 do relatório da Fase 2.
String pairingErrorMessage(FfiError error) {
  switch (error) {
    case FfiError.qrMalformed:
      return 'Não foi possível ler este código. Tente novamente com mais luz.';
    case FfiError.qrBadSignature:
      return 'O código lido está corrompido ou foi alterado.';
    case FfiError.selfPairing:
      return 'Este é o seu próprio código — peça para a outra pessoa mostrar o dela.';
    case FfiError.forgedKey:
      return 'Este código não é válido e pode ter sido manipulado. Não continue o pareamento.';
    case FfiError.storeFailure:
      return 'Não foi possível salvar o contato. Tente novamente.';
    case FfiError.contactNotFound:
      return 'Contato não encontrado.';
    case FfiError.internal:
      return 'Ocorreu um erro inesperado. Tente novamente.';
  }
}
