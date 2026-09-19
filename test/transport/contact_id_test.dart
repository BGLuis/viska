import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/p2p_transport.dart';

void main() {
  group('ContactId', () {
    test('dois ContactId com os mesmos bytes são iguais', () {
      final a = ContactId(List.generate(16, (i) => i));
      final b = ContactId(List.generate(16, (i) => i));

      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('ContactId com bytes diferentes não são iguais', () {
      final a = ContactId(List.generate(16, (i) => i));
      final b = ContactId(List.generate(16, (i) => i + 1));

      expect(a, isNot(equals(b)));
    });

    test('ContactId com comprimentos diferentes não são iguais', () {
      final a = ContactId([1, 2, 3]);
      final b = ContactId([1, 2, 3, 4]);

      expect(a, isNot(equals(b)));
    });

    test('funciona como chave de Map (o que o router depende)', () {
      final map = <ContactId, String>{};
      final key1 = ContactId(List.generate(16, (i) => i));
      final key2 = ContactId(List.generate(16, (i) => i)); // mesmo conteúdo, instância diferente

      map[key1] = 'alice';
      expect(map[key2], 'alice');
      expect(map.containsKey(key2), isTrue);
    });

    test('não é igual a um objeto de outro tipo', () {
      final a = ContactId([1, 2, 3]);
      // ignore: unrelated_type_equality_checks
      expect(a == 'não é um ContactId', isFalse);
    });
  });
}
