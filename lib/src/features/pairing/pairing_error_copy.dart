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
    // As variantes abaixo não são produzidas pelo fluxo de pareamento — só
    // por chamadas de sessão/mensagem (Fase 3) ou de transferência de
    // arquivo/áudio (Fase 4/5) — mas o switch precisa ser exaustivo sobre o
    // enum inteiro, que é compartilhado entre as telas.
    case FfiError.sessionExpired:
      return 'A sessão de conversa expirou. Abra uma nova.';
    case FfiError.noActiveSession:
      return 'Nenhuma sessão de conversa está aberta com este contato.';
    case FfiError.fileCorrupted:
      return 'O arquivo recebido está corrompido ou foi adulterado.';
    case FfiError.locked:
      return 'O aplicativo está bloqueado. Desbloqueie para continuar.';
    case FfiError.internal:
      return 'Ocorreu um erro inesperado. Tente novamente.';
  }
}
