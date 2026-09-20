import 'dart:async';
import 'dart:typed_data';

import 'p2p_transport.dart';
import 'webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;

/// Implementado opcionalmente por um candidato de [SelectingP2PTransport]
/// que sabe, sem tentar conectar, se está mesmo alcançável agora — evita
/// esperar o timeout de um transporte que já sabemos indisponível. Um
/// candidato que não implementa esta interface é sempre tentado (é o caso
/// de `WebrtcP2PTransport`, o fallback garantido no fim da lista).
abstract class TransportReadiness {
  bool get isLikelyReachable;
}

/// [P2PTransport] que escolhe, entre vários candidatos em ordem de
/// prioridade, o primeiro que conseguir conectar — Fase 6, F3.
///
/// Cumpre literalmente a promessa já registrada no doc-comment de
/// [P2PTransportRouter] desde a Fase 3: a Fase 6 adiciona implementações de
/// [P2PTransport] e escolhe por prioridade sem mudar esse contrato nem quem
/// o consome. `P2PTransportRouter` continua vendo um único [P2PTransport]
/// por contato — só que agora ele pode ser, por baixo, LAN, Wi-Fi Aware,
/// MultipeerConnectivity ou WebRTC, dependendo do que responder primeiro.
class SelectingP2PTransport implements P2PTransport {
  SelectingP2PTransport({
    required List<P2PTransport> candidates,
    Duration candidateTimeout = const Duration(seconds: 8),
  })  : _candidates = candidates,
        _candidateTimeout = candidateTimeout;

  final List<P2PTransport> _candidates;
  final Duration _candidateTimeout;

  final _incomingController = StreamController<Uint8List>.broadcast();
  final _incomingFileController = StreamController<Uint8List>.broadcast();
  final _connectionEventsController = StreamController<TransportConnectionEvent>.broadcast();
  final _selectionDone = Completer<void>();

  P2PTransport? _chosen;
  bool _connectStarted = false;
  final _closedCandidates = <P2PTransport>{};

  @override
  Stream<Uint8List> get incoming => _incomingController.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFileController.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEventsController.stream;

  /// O candidato escolhido — só para inspeção/teste, `null` antes da seleção
  /// terminar (ou se todos os candidatos falharem).
  P2PTransport? get chosen => _chosen;

  @override
  Future<void> connect() async {
    if (_connectStarted) return;
    _connectStarted = true;

    for (final candidate in _candidates) {
      if (candidate is TransportReadiness && !(candidate as TransportReadiness).isLikelyReachable) {
        continue;
      }
      try {
        await candidate.connect().timeout(_candidateTimeout);
      } catch (_) {
        await _closeCandidate(candidate);
        continue;
      }

      _chosen = candidate;
      candidate.incoming.listen(_incomingController.add);
      candidate.incomingFile.listen(_incomingFileController.add);
      candidate.connectionEvents.listen(_connectionEventsController.add);
      _selectionDone.complete();
      _connectionEventsController.add(
        const TransportConnectionEvent(TransportConnectionState.connected),
      );
      return;
    }

    final error = StateError('Nenhum transporte candidato conseguiu conectar');
    _selectionDone.completeError(error);
    _connectionEventsController.add(
      const TransportConnectionEvent(
        TransportConnectionState.failed,
        reason: 'nenhum transporte candidato conseguiu conectar',
      ),
    );
    throw error;
  }

  @override
  Future<void> send(Uint8List envelope) async {
    await _selectionDone.future;
    await _chosen!.send(envelope);
  }

  @override
  Future<void> sendFile(Uint8List bytes) async {
    await _selectionDone.future;
    await _chosen!.sendFile(bytes);
  }

  @override
  Future<void> close() async {
    // Fecha todos os candidatos construídos, não só o escolhido — os que já
    // perderam (fechados pelo `catch` de `connect()`) são pulados via
    // `_closedCandidates`, para não fechar duas vezes o mesmo candidato; os
    // nunca tentados (ex.: a lista tinha mais candidatos depois do
    // escolhido) e o próprio escolhido são fechados aqui pela primeira vez.
    for (final candidate in _candidates) {
      await _closeCandidate(candidate);
    }
    if (!_incomingController.isClosed) await _incomingController.close();
    if (!_incomingFileController.isClosed) await _incomingFileController.close();
    if (!_connectionEventsController.isClosed) await _connectionEventsController.close();
  }

  Future<void> _closeCandidate(P2PTransport candidate) async {
    if (_closedCandidates.add(candidate)) {
      await candidate.close();
    }
  }
}
