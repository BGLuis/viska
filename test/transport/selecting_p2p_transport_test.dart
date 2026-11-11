import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/selecting_p2p_transport.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

class _FakeTransport implements P2PTransport {
  _FakeTransport({this.connectDelay, this.connectError, this.closeGate});

  final Duration? connectDelay;
  final Object? connectError;

  /// Quando presente, `close()` fica esperando o gate e só então emite
  /// `closed` — imita o `WebrtcTransport.close()`, que emite o evento depois
  /// de aguardar `_pc.close()`.
  final Completer<void>? closeGate;

  var connectCalls = 0;
  var closeCalls = 0;
  final sendCalls = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Future<void> connect() async {
    connectCalls++;
    if (connectDelay != null) await Future<void>.delayed(connectDelay!);
    if (connectError != null) throw connectError!;
  }

  @override
  Future<void> send(Uint8List envelope) async => sendCalls.add(envelope);

  @override
  Future<void> sendFile(Uint8List bytes) async {}

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;

  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;

  @override
  Future<void> close() async {
    closeCalls++;
    final gate = closeGate;
    if (gate == null) return;
    await gate.future;
    _connectionEvents.add(const TransportConnectionEvent(TransportConnectionState.closed));
    _incoming.add(Uint8List.fromList([9]));
    _incomingFile.add(Uint8List.fromList([9]));
  }

  void emitIncoming(Uint8List bytes) => _incoming.add(bytes);
  void emitEvent(TransportConnectionEvent event) => _connectionEvents.add(event);
}

// Distingue o erro de "fechado" de um `StateError` qualquer, inclusive o
// "Cannot add new events" que este teste existe para impedir.
final _closedDuringSelection = isA<StateError>().having((e) => e.message, 'message', contains('fechado'));

/// Roda [body] e devolve os erros que escaparam para a zona — é onde o
/// `CrashBarrier` os veria.
Future<List<Object>> _zoneErrorsOf(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } finally {
      done.complete();
    }
  }, (e, _) => errors.add(e));
  await done.future;
  return errors;
}

class _UnreachableFakeTransport extends _FakeTransport implements TransportReadiness {
  @override
  bool get isLikelyReachable => false;
}

void main() {
  group('SelectingP2PTransport', () {
    test('chooses first candidate that connects successfully', () async {
      final first = _FakeTransport();
      final second = _FakeTransport();
      final selecting = SelectingP2PTransport(candidates: [first, second]);

      await selecting.connect();

      expect(selecting.chosen, same(first));
      expect(first.connectCalls, 1);
      expect(second.connectCalls, 0);
    });

    test('skips candidate marked as unavailable without calling connect', () async {
      final unreachable = _UnreachableFakeTransport();
      final reachable = _FakeTransport();
      final selecting = SelectingP2PTransport(candidates: [unreachable, reachable]);

      await selecting.connect();

      expect(unreachable.connectCalls, 0);
      expect(selecting.chosen, same(reachable));
    });

    test('falls back to next candidate when first fails or times out', () async {
      final failing = _FakeTransport(connectError: StateError('não conectou'));
      final slow = _FakeTransport(connectDelay: const Duration(seconds: 30));
      final working = _FakeTransport();
      final selecting = SelectingP2PTransport(
        candidates: [failing, slow, working],
        candidateTimeout: const Duration(milliseconds: 50),
      );

      await selecting.connect();

      expect(selecting.chosen, same(working));
      expect(failing.closeCalls, 1, reason: 'candidato que falhou deve ser fechado');
      expect(slow.closeCalls, 1, reason: 'candidato que expirou deve ser fechado');
    });

    test('send waits for selection to finish before delegating', () async {
      final slow = _FakeTransport(connectDelay: const Duration(milliseconds: 100));
      final selecting = SelectingP2PTransport(candidates: [slow]);

      final connectFuture = selecting.connect();
      final sendFuture = selecting.send(Uint8List.fromList([1, 2, 3]));

      await Future.wait([connectFuture, sendFuture]);

      expect(slow.sendCalls, [Uint8List.fromList([1, 2, 3])]);
    });

    test('close closes all constructed candidates, not just chosen one', () async {
      final chosen = _FakeTransport();
      final loser = _FakeTransport(connectError: StateError('perdeu'));
      final selecting = SelectingP2PTransport(candidates: [loser, chosen]);

      await selecting.connect();
      await selecting.close();

      expect(chosen.closeCalls, 1);
      expect(loser.closeCalls, 1, reason: 'já fechado pelo catch, mas close() não pode pular ninguém');
    });

    test('with a single candidate behavior is identical to existing', () async {
      final only = _FakeTransport();
      final selecting = SelectingP2PTransport(candidates: [only]);

      await selecting.connect();
      final received = <Uint8List>[];
      selecting.incoming.listen(received.add);
      only.emitIncoming(Uint8List.fromList([7]));
      await Future<void>.delayed(Duration.zero);

      await selecting.send(Uint8List.fromList([1]));

      expect(selecting.chosen, same(only));
      expect(only.sendCalls, [Uint8List.fromList([1])]);
      expect(received, [Uint8List.fromList([7])]);
    });

    test('all candidates failing causes connect and send to reject', () async {
      final a = _FakeTransport(connectError: StateError('a'));
      final b = _FakeTransport(connectError: StateError('b'));
      final selecting = SelectingP2PTransport(candidates: [a, b]);

      await expectLater(selecting.connect(), throwsA(isA<StateError>()));
      await expectLater(selecting.send(Uint8List.fromList([1])), throwsA(isA<StateError>()));
    });

    test('forwards failed from chosen candidate before close', () async {
      final only = _FakeTransport();
      final selecting = SelectingP2PTransport(candidates: [only]);
      await selecting.connect();
      final events = <TransportConnectionEvent>[];
      selecting.connectionEvents.listen(events.add);

      only.emitEvent(const TransportConnectionEvent(TransportConnectionState.failed));
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.state), [TransportConnectionState.failed]);
    });

    test('candidate event after close does not raise unhandled error', () async {
      final gate = Completer<void>();
      final only = _FakeTransport(closeGate: gate);
      final selecting = SelectingP2PTransport(candidates: [only]);
      await selecting.connect();

      final errors = await _zoneErrorsOf(() async {
        // A segunda chamada (o roteador reagindo a `failed`) retorna e fecha os
        // controladores enquanto a primeira ainda espera o candidato.
        final first = selecting.close();
        await selecting.close();
        gate.complete();
        await first;
      });

      expect(errors, isEmpty);
    });

    test('candidate data after close does not raise unhandled error', () async {
      final gate = Completer<void>();
      final only = _FakeTransport(closeGate: gate);
      final selecting = SelectingP2PTransport(candidates: [only]);
      await selecting.connect();
      final received = <Uint8List>[];
      selecting.incoming.listen(received.add);

      final errors = await _zoneErrorsOf(() async {
        final first = selecting.close();
        await selecting.close();
        gate.complete();
        await first;
      });

      expect(errors, isEmpty);
      expect(received, isEmpty);
    });

    test('close during connect rejects connect and send without unhandled error', () async {
      final slow = _FakeTransport(connectDelay: const Duration(milliseconds: 50));
      late SelectingP2PTransport selecting;

      final errors = await _zoneErrorsOf(() async {
        selecting = SelectingP2PTransport(candidates: [slow]);
        final connectFuture = selecting.connect();
        final sendFuture = selecting.send(Uint8List.fromList([1]));
        // Expectativas antes do `close()`: um erro sem ouvinte seria reportado
        // à zona e mascararia o que o teste mede.
        final connectCheck = expectLater(connectFuture, throwsA(_closedDuringSelection));
        final sendCheck = expectLater(sendFuture, throwsA(_closedDuringSelection));
        await selecting.close();
        await connectCheck;
        await sendCheck;
      });

      expect(errors, isEmpty);
      expect(selecting.chosen, isNull);
      expect(slow.closeCalls, 1);
    });

    test('close during connect when every candidate fails does not raise unhandled error', () async {
      final failing = _FakeTransport(
        connectDelay: const Duration(milliseconds: 50),
        connectError: StateError('falhou'),
      );
      final selecting = SelectingP2PTransport(candidates: [failing]);

      final errors = await _zoneErrorsOf(() async {
        final connectFuture = selecting.connect();
        final connectCheck = expectLater(connectFuture, throwsA(_closedDuringSelection));
        await selecting.close();
        await connectCheck;
      });

      expect(errors, isEmpty);
    });
  });
}
