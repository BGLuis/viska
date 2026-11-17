import 'dart:typed_data';

import 'webrtc_transport.dart' show TransportConnectionEvent;

/// Identifica um contato pelo `device_id` (16 bytes) — usado como chave de
/// `Map` pelo [P2PTransportRouter], então precisa de igualdade estrutural em
/// vez da igualdade por identidade que `List<int>`/`Uint8List` usam por
/// padrão.
class ContactId {
  ContactId(Iterable<int> deviceId)
      : deviceId = Uint8List.fromList(List<int>.from(deviceId));

  final Uint8List deviceId;

  @override
  bool operator ==(Object other) {
    if (other is! ContactId || other.deviceId.length != deviceId.length) {
      return false;
    }
    for (var i = 0; i < deviceId.length; i++) {
      if (deviceId[i] != other.deviceId[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(deviceId);

  @override
  String toString() => 'ContactId(${deviceId.map(
        (b) => b.toRadixString(16).padLeft(2, '0'),
      ).join()})';
}

/// Lançada por [P2PTransport.send]/[P2PTransport.sendFile] quando a conexão
/// já caiu e o envelope **não** foi entregue ao par. Quem chama deve tratar o
/// envio como não feito (a mensagem segue pendente), nunca como enviado.
///
/// Só os transportes que detectam a queda por conta própria (hoje
/// `LanTransport`) a lançam; os demais repassam o erro da camada de baixo, e
/// por isso os chamadores capturam qualquer exceção, não só esta.
class TransportUnavailableException implements Exception {
  const TransportUnavailableException([this.message = 'transporte indisponível']);

  final String message;

  @override
  String toString() => 'TransportUnavailableException: $message';
}

/// Um envio já aceito ficou sem progresso pelo limite de inatividade: o par
/// sumiu ou encerrou a transferência sem o aviso chegar. Ela continua no banco
/// e volta na próxima retomada (docs/protocol.md §7.5).
class TransferStalledException implements Exception {
  const TransferStalledException();

  @override
  String toString() => 'TransferStalledException: envio sem progresso';
}

/// Um transporte P2P com um único contato — Fase 3, F5.
///
/// `WebrtcP2PTransport` é a única implementação nesta fase; a Fase 6 (rádios
/// locais) registra mais no [P2PTransportRouter] sem precisar mudar este
/// contrato nem quem o consome (a tela de chat).
abstract class P2PTransport {
  /// Inicia a conexão (sinalização, oferta/resposta, ICE). Idempotente:
  /// chamar de novo depois de já conectado não reinicia nada.
  Future<void> connect();

  /// Envia um envelope já cifrado — bytes crus, prontos para o transporte.
  Future<void> send(Uint8List envelope);

  /// Como [send], no canal `file` — símbolo RaptorQ ou pedaço de nota de
  /// voz, já selado com chave própria fora do ratchet (Fase 4/5).
  Future<void> sendFile(Uint8List bytes);

  /// Envelopes recebidos, ainda cifrados — prontos para `Core.receiveIncoming`.
  Stream<Uint8List> get incoming;

  /// Como [incoming], no canal `file`.
  Stream<Uint8List> get incomingFile;

  Stream<TransportConnectionEvent> get connectionEvents;

  Future<void> close();
}
