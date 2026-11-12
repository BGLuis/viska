import 'package:viska/src/rust/ffi/types.dart';

/// Saúde da sessão com um contato, como a conversa a enxerga: o último estado
/// que o Rust publicou e o que a UI deve fazer com ele.
///
/// Classe pura, sem notificar ninguém: quem a usa decide quando redesenhar.
/// Mora fora do `ChatController` para que o "recusar se quebrada" dos pontos de
/// envio e o texto do aviso fiquem num lugar só.
class SessionHealth {
  SessionStateKind? _state;
  var _needsRehandshake = false;
  var _streamed = false;

  /// Já chegou algum estado pelo stream do Rust. A leitura avulsa de
  /// `ChatController.initialize` só vale até lá: depois dela o evento é mais
  /// recente.
  bool get streamed => _streamed;

  /// Sessão utilizável: estabelecida e sem pedido de renovação.
  bool get isEstablished => _state == SessionStateKind.established && !_needsRehandshake;

  /// Sessão que só `reset_session` recupera: falhou, ou passou do limiar de
  /// §11.2 e o Rust recusa cifrar mais mensagens.
  bool get isBroken => _state == SessionStateKind.failed || _needsRehandshake;

  /// Qual dos dois motivos vale para o aviso: a renovação preventiva não é uma
  /// falha, e o texto precisa dizer isso.
  bool get isFailed => _state == SessionStateKind.failed;

  /// Aplica um estado e diz se algo mudou. [fromStream] distingue o evento do
  /// Rust da leitura avulsa feita na abertura da conversa.
  bool apply(SessionStateKind? state, bool needsRehandshake, {required bool fromStream}) {
    if (fromStream) _streamed = true;
    if (_state == state && _needsRehandshake == needsRehandshake) return false;
    _state = state;
    _needsRehandshake = needsRehandshake;
    return true;
  }

  static const brokenSendMessage =
      'A sessão segura com este contato não está ativa. Reconecte para enviar arquivos e notas de voz.';

  /// Título e texto do aviso; só fazem sentido com [isBroken].
  String get bannerTitle => isFailed ? 'SESSÃO FALHOU' : 'SESSÃO PRECISA SER RENOVADA';

  String get bannerMessage {
    final cause = isFailed
        ? 'A sessão segura com este contato falhou.'
        : 'Esta sessão enviou mensagens demais e precisa ser renovada.';
    // O contato é avisado e acompanha sozinho (docs/protocol.md §11.4), mas
    // só quando os dois estiverem conectados.
    return '$cause Reconectar abre uma sessão nova e avisa o contato quando vocês '
        'estiverem conectados. Mensagens de texto ficam na fila até lá.';
  }
}
