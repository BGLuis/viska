import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/outbox.dart';

void main() {
  group('JitteredOutbox', () {
    test('sends a message applying jitter before sending', () async {
      final sent = <Uint8List>[];
      var jitterCalls = 0;

      final outbox = JitteredOutbox(
        rawSend: (bytes) async {
          sent.add(bytes);
        },
        sampleJitter: () async {
          jitterCalls++;
          return Duration.zero;
        },
      );

      await outbox.enqueue(Uint8List.fromList([1, 2, 3]));

      expect(sent, [Uint8List.fromList([1, 2, 3])]);
      expect(jitterCalls, 1);
    });

    test('sends in order, one at a time', () async {
      final order = <int>[];
      final outbox = JitteredOutbox(
        rawSend: (bytes) async {
          // Simula latência variável de rede — se o envio corresse em
          // paralelo, a ordem de chegada em `order` poderia inverter.
          await Future<void>.delayed(Duration(milliseconds: bytes.first == 0 ? 5 : 0));
          order.add(bytes.first);
        },
        sampleJitter: () async => Duration.zero,
      );

      final futures = [
        outbox.enqueue(Uint8List.fromList([0])),
        outbox.enqueue(Uint8List.fromList([1])),
        outbox.enqueue(Uint8List.fromList([2])),
      ];
      await Future.wait(futures);

      expect(order, [0, 1, 2]);
    });

    test('each enqueue resolves only when that specific message completes', () async {
      final completedOrder = <int>[];
      final outbox = JitteredOutbox(
        rawSend: (bytes) async {},
        sampleJitter: () async => Duration.zero,
      );

      unawaited(outbox.enqueue(Uint8List.fromList([1])).then((_) => completedOrder.add(1)));
      unawaited(outbox.enqueue(Uint8List.fromList([2])).then((_) => completedOrder.add(2)));

      // Dá tempo para as duas microtasks/timers rodarem.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(completedOrder, [1, 2]);
    });

    test('a send failure rejects only that message, not subsequent ones', () async {
      var attempt = 0;
      final sent = <Uint8List>[];
      final outbox = JitteredOutbox(
        rawSend: (bytes) async {
          attempt++;
          if (attempt == 1) {
            throw Exception('falha simulada de rede');
          }
          sent.add(bytes);
        },
        sampleJitter: () async => Duration.zero,
      );

      await expectLater(
        outbox.enqueue(Uint8List.fromList([1])),
        throwsException,
      );
      await outbox.enqueue(Uint8List.fromList([2]));

      expect(sent, [Uint8List.fromList([2])]);
    });

    test('pendingCount reflects queue while draining', () async {
      final gate = Completer<void>();
      final outbox = JitteredOutbox(
        rawSend: (bytes) => gate.future,
        sampleJitter: () async => Duration.zero,
      );

      final first = outbox.enqueue(Uint8List.fromList([1]));
      final second = outbox.enqueue(Uint8List.fromList([2]));

      // Várias voltas do event loop para garantir que a cadeia interna de
      // `await`s (jitter, delay, rawSend) da primeira mensagem já chegou até
      // `gate.future` antes de checar o estado da fila — uma única espera
      // de duração zero não garante isso de forma confiável.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      // A primeira já está "em voo" (presa em `gate`); a segunda ainda
      // espera na fila.
      expect(outbox.pendingCount, 1);

      gate.complete();
      await Future.wait([first, second]);
      expect(outbox.pendingCount, 0);
    });

    test('enqueue after close() rejects immediately', () async {
      final outbox = JitteredOutbox(
        rawSend: (bytes) async {},
        sampleJitter: () async => Duration.zero,
      );
      outbox.close();

      await expectLater(
        outbox.enqueue(Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });
  });
}
