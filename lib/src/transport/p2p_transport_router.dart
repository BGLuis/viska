import 'dart:async';
import 'dart:typed_data';

import 'package:viska/src/rust/ffi/core.dart';

import 'p2p_transport.dart';
import 'selecting_p2p_transport.dart';
import 'transport_candidates.dart';
import 'webrtc_transport.dart';

/// Roteia envio/recebimento por contato para o transporte certo — Fase 3, F5.
///
/// A fábrica padrão devolve um [SelectingP2PTransport] (Fase 6, F3) que
/// tenta, em ordem de prioridade, LAN > Wi-Fi Aware/MultipeerConnectivity
/// (quando suportados) > WebRTC — o primeiro que conectar é o escolhido.
/// BLE **não** entra nessa lista: não carrega dados nesta fase, só descoberta
/// (`NearbyPresenceService`, Fase 6 F2) — mesmo raciocínio de `docs/protocol.md`
/// §9.1.
///
/// Cria um [P2PTransport] por contato, sob demanda, na primeira vez que
/// qualquer um dos três métodos é chamado para aquele contato — e chama
/// [P2PTransport.connect] exatamente uma vez nesse momento.
class P2PTransportRouter {
  P2PTransportRouter({
    required Core core,
    P2PTransport Function(Core core, ContactId contactId)? transportFactory,
  })  : _core = core,
        _transportFactory = transportFactory ?? _defaultFactory;

  final Core _core;
  final P2PTransport Function(Core, ContactId) _transportFactory;
  final Map<ContactId, _RoutedTransport> _routed = {};

  /// Envia `envelope` (já cifrado) para `contact` — conecta o transporte
  /// desse contato primeiro, se ainda não existir.
  Future<void> sendToContact(ContactId contact, Uint8List envelope) async {
    final routed = _ensure(contact);
    await routed.connectFuture;
    await routed.transport.send(envelope);
  }

  /// Envelopes recebidos de `contact`, ainda cifrados.
  Stream<Uint8List> incomingFor(ContactId contact) => _ensure(contact).transport.incoming;

  /// Como [sendToContact], no canal `file` — símbolo RaptorQ ou pedaço de
  /// nota de voz, já selado (Fase 4/5).
  Future<void> sendFileToContact(ContactId contact, Uint8List bytes) async {
    final routed = _ensure(contact);
    await routed.connectFuture;
    await routed.transport.sendFile(bytes);
  }

  /// Como [incomingFor], no canal `file`.
  Stream<Uint8List> incomingFileFor(ContactId contact) =>
      _ensure(contact).transport.incomingFile;

  Stream<TransportConnectionEvent> connectionEventsFor(ContactId contact) =>
      _ensure(contact).transport.connectionEvents;

  /// Fecha e esquece o transporte de um contato — a próxima chamada de
  /// qualquer método para ele cria um transporte novo do zero.
  Future<void> closeContact(ContactId contact) async {
    final routed = _routed.remove(contact);
    if (routed == null) return;
    await routed.transport.close();
  }

  Future<void> closeAll() async {
    final contacts = _routed.keys.toList();
    for (final contact in contacts) {
      await closeContact(contact);
    }
  }

  _RoutedTransport _ensure(ContactId contact) {
    return _routed.putIfAbsent(contact, () {
      final transport = _transportFactory(_core, contact);
      return _RoutedTransport(transport, transport.connect());
    });
  }

  static P2PTransport _defaultFactory(Core core, ContactId contactId) =>
      SelectingP2PTransport(candidates: buildDefaultCandidates(core, contactId));
}

class _RoutedTransport {
  _RoutedTransport(this.transport, this.connectFuture);

  final P2PTransport transport;

  /// Guardada para que [P2PTransportRouter.sendToContact] espere a conexão
  /// terminar de iniciar antes do primeiro envio — `incomingFor`/
  /// `connectionEventsFor` não precisam esperar, porque devolvem `Stream`s
  /// que só emitem depois que houver algo para emitir de qualquer forma.
  final Future<void> connectFuture;
}
