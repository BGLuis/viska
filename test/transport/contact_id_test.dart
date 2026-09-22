import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/p2p_transport.dart';

void main() {
  group('ContactId', () {
    test('two ContactIds with the same bytes are equal', () {
      final a = ContactId(List.generate(16, (i) => i));
      final b = ContactId(List.generate(16, (i) => i));

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('ContactIds with different bytes are not equal', () {
      final a = ContactId(List.generate(16, (i) => i));
      final b = ContactId(List.generate(16, (i) => i + 1));

      expect(a, isNot(equals(b)));
    });

    test('ContactIds with different lengths are not equal', () {
      final a = ContactId([1, 2, 3]);
      final b = ContactId([1, 2, 3, 4]);

      expect(a, isNot(equals(b)));
    });

    test('works as a Map key (which the router depends on)', () {
      final map = <ContactId, String>{};
      final key1 = ContactId(List.generate(16, (i) => i));
      final key2 = ContactId(List.generate(16, (i) => i)); // mesmo conteúdo, instância diferente

      map[key1] = 'alice';
      expect(map[key2], 'alice');
      expect(map.containsKey(key2), isTrue);
    });

    test('is not equal to an object of another type', () {
      final a = ContactId([1, 2, 3]);
      // ignore: unrelated_type_equality_checks
      expect(a == 'não é um ContactId', isFalse);
    });
  });
}
