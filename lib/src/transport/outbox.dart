import 'dart:async';
import 'dart:typed_data';

/// Fila de envio que aplica jitter antes de cada mensagem — `docs/protocol.md`
/// §6.5, decisão 2.5 do relatório da Fase 3: o Rust só amostra o atraso
/// (`sampleJitterDelayMs`, via FFI); quem efetivamente dorme é esta classe,
/// porque só a camada de transporte sabe qual runtime assíncrono está em uso.
///
/// Existe separada de [WebrtcTransport] de propósito: nada aqui conhece
/// `RTCDataChannel` — só uma função de envio (`rawSend`) e uma de
/// amostragem de atraso (`sampleJitter`), injetadas pelo chamador. Isso é o
/// que torna a fila inteira testável sem um `RTCPeerConnection` de verdade,
/// que exige canal de plataforma nativo indisponível em `flutter test`.
///
/// Envia em ordem, um de cada vez: uma mensagem começa a ser processada só
/// depois que a anterior terminou (com sucesso ou falha), nunca em paralelo
/// — importante para uma conversa de texto, onde a ordem de chegada importa.
/// Uma falha de envio não impede as mensagens seguintes; só rejeita a
/// promessa daquela mensagem específica.
class JitteredOutbox {
  JitteredOutbox({
    required Future<void> Function(Uint8List envelope) rawSend,
    required Future<Duration> Function() sampleJitter,
  })  : _rawSend = rawSend,
        _sampleJitter = sampleJitter;

  final Future<void> Function(Uint8List envelope) _rawSend;
  final Future<Duration> Function() _sampleJitter;

  final List<_QueuedEnvelope> _queue = [];
  bool _draining = false;
  bool _closed = false;

  /// Enfileira `envelope` para envio. A promessa devolvida resolve quando
  /// **esta** mensagem específica terminar de ser enviada (ou rejeita se o
  /// envio falhar) — não quando a fila inteira esvaziar.
  Future<void> enqueue(Uint8List envelope) {
    if (_closed) {
      return Future.error(StateError('JitteredOutbox já foi fechada'));
    }

    final completer = Completer<void>();
    _queue.add(_QueuedEnvelope(envelope, completer));
    if (!_draining) {
      _draining = true;
      unawaited(_drain());
    }
    return completer.future;
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      try {
        final delay = await _sampleJitter();
        await Future<void>.delayed(delay);
        await _rawSend(item.envelope);
        item.completer.complete();
      } catch (error, stackTrace) {
        item.completer.completeError(error, stackTrace);
      }
    }
    _draining = false;
  }

  /// Quantas mensagens ainda estão na fila (incluindo a que está sendo
  /// processada agora, se houver) — só para inspeção/teste.
  int get pendingCount => _queue.length;

  /// Impede novos `enqueue`; mensagens já enfileiradas continuam sendo
  /// drenadas normalmente.
  void close() {
    _closed = true;
  }
}

class _QueuedEnvelope {
  _QueuedEnvelope(this.envelope, this.completer);

  final Uint8List envelope;
  final Completer<void> completer;
}
