import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

import '../../transport/p2p_transport.dart';
import '../../transport/p2p_transport_router.dart';
import '../../transport/webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;

/// Estado e lógica de uma conversa com um contato — Fase 3, F6.
///
/// `ChangeNotifier` puro do Flutter, não uma lib de state management: mesmo
/// padrão do resto do projeto (`StatefulWidget` + `setState`), só que a
/// lógica fica separada da árvore de widgets para poder ser testada com
/// dublês de `Core`/`P2PTransportRouter`, sem nenhuma UI — mesmo raciocínio
/// que motivou extrair `WebrtcP2PTransport` na Fase 3, F5.
///
/// Dono de uma peça que não tinha lar em nenhuma fase anterior: decidir, a
/// cada byte cru que chega do transporte, se é uma mensagem de handshake
/// (`Core.feedHandshake`) ou um envelope de sessão já estabelecida
/// (`Core.decryptIncoming`). F5 devolve bytes crus de propósito — não sabe
/// nada de sessão viska — e a decisão de qual FFI chamar é puramente “a
/// sessão já está `Established`?”, a mesma pergunta que `Session` já resolve
/// internamente no lado Rust (`docs/protocol.md` §11.1), só que agora
/// respondida do lado Dart para saber qual método FFI chamar.
class ChatController extends ChangeNotifier {
  ChatController({
    required Core core,
    required P2PTransportRouter router,
    required ContactId contactId,
  })  : _core = core,
        _router = router,
        _contactId = contactId;

  final Core _core;
  final P2PTransportRouter _router;
  final ContactId _contactId;

  List<MessageDto> _messages = [];
  List<MessageDto> get messages => List.unmodifiable(_messages);

  bool _established = false;
  bool get isEstablished => _established;

  String? _connectionError;
  String? get connectionError => _connectionError;

  bool _sending = false;
  bool get isSending => _sending;

  StreamSubscription<Uint8List>? _incomingSub;
  StreamSubscription<TransportConnectionEvent>? _connectionSub;
  var _disposed = false;

  /// Carrega o histórico, conecta o transporte (via [P2PTransportRouter],
  /// que faz isso sob demanda) e tenta publicar a mensagem de handshake se
  /// formos iniciador. Chamar uma vez, normalmente em `initState`.
  Future<void> initialize() async {
    await _refreshMessages();

    _incomingSub = _router.incomingFor(_contactId).listen(_handleIncomingRaw);
    _connectionSub = _router.connectionEventsFor(_contactId).listen(_handleConnectionEvent);

    unawaited(_tryPublishOutgoingHandshake());
  }

  /// Grava `body` como `pending` (eco otimista) e tenta enviar na hora, se a
  /// sessão já estiver pronta. Se não estiver, a mensagem fica `pending` até
  /// o handshake terminar e o outbox drenar (`_flushPending`).
  Future<void> sendText(String body) async {
    if (body.isEmpty) return;

    _sending = true;
    notifyListeners();
    try {
      final sealed = await _core.sealOutgoingText(
        peerDeviceId: _contactId.deviceId,
        body: body,
      );
      await _refreshMessages();
      if (sealed.bytes != null) {
        await _sendSealed(sealed.messageId, sealed.bytes!);
      }
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  Future<void> _handleIncomingRaw(Uint8List bytes) async {
    final status = await _core.sessionStatus(peerDeviceId: _contactId.deviceId);
    final alreadyEstablished = status?.state == SessionStateKind.established;

    if (!alreadyEstablished) {
      final response = await _core.feedHandshake(
        peerDeviceId: _contactId.deviceId,
        bytes: bytes,
      );
      if (response != null) {
        await _router.sendToContact(_contactId, response);
      }
      await _refreshEstablishedStateAndFlushIfNeeded();
      return;
    }

    final incoming = await _core.decryptIncoming(
      peerDeviceId: _contactId.deviceId,
      envelope: bytes,
    );
    // `null`: o AEAD falhou — mensagem descartada, mesma política de
    // silêncio de `Session::decrypt_incoming`. `isTyping`: indicador
    // efêmero (`docs/protocol.md` §6.2) — nada nesta fase produz um, e não
    // há UI dedicada para ele ainda; ignorado sem erro de qualquer forma.
    if (incoming == null || incoming.isTyping) return;

    await _refreshMessages();
  }

  void _handleConnectionEvent(TransportConnectionEvent event) {
    if (event.state == TransportConnectionState.failed) {
      _connectionError = event.reason;
      notifyListeners();
    } else if (event.state == TransportConnectionState.connected) {
      _connectionError = null;
      notifyListeners();
    }
  }

  Future<void> _tryPublishOutgoingHandshake() async {
    final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
    if (status.state == SessionStateKind.established) {
      await _refreshEstablishedStateAndFlushIfNeeded();
      return;
    }

    final outgoing = status.outgoingHandshake;
    if (outgoing != null) {
      // `P2PTransportRouter.sendToContact` espera o canal `control` abrir de
      // verdade antes de mandar (ver `WebrtcTransport.send`, Fase 3 F3) —
      // então isto não manda a INIT cedo demais, só fica pendurado até dar.
      await _router.sendToContact(_contactId, outgoing);
    }
  }

  Future<void> _refreshEstablishedStateAndFlushIfNeeded() async {
    final status = await _core.sessionStatus(peerDeviceId: _contactId.deviceId);
    final established = status?.state == SessionStateKind.established;
    if (established && !_established) {
      _established = true;
      notifyListeners();
      await _flushPending();
    } else if (established != _established) {
      _established = established;
      notifyListeners();
    }
  }

  Future<void> _flushPending() async {
    final sealed = await _core.flushPending(peerDeviceId: _contactId.deviceId);
    for (final message in sealed) {
      final bytes = message.bytes;
      if (bytes != null) {
        await _sendSealed(message.messageId, bytes);
      }
    }
  }

  Future<void> _sendSealed(int messageId, Uint8List bytes) async {
    await _router.sendToContact(_contactId, bytes);
    await _core.markMessageSent(messageId: messageId);
    await _refreshMessages();
  }

  Future<void> _refreshMessages() async {
    final loaded = await _core.listMessages(peerDeviceId: _contactId.deviceId);
    if (_disposed) return;
    _messages = loaded;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_incomingSub?.cancel());
    unawaited(_connectionSub?.cancel());
    super.dispose();
  }
}
