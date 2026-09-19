import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/pairing/pairing_error_copy.dart';
import 'package:viska/src/rust/ffi/error.dart';

void main() {
  test('toda variante de FfiError produz uma mensagem', () {
    for (final error in FfiError.values) {
      expect(pairingErrorMessage(error), isNotEmpty);
    }
  });

  test('forgedKey e selfPairing tem mensagens distintas de qrMalformed', () {
    // A distinção que a UI não pode perder: um QR forjado (ponto de ordem
    // baixa) é sinal de ataque, não de leitura ruim — ver armadilha 4 do
    // relatório da Fase 2.
    final malformed = pairingErrorMessage(FfiError.qrMalformed);
    final forged = pairingErrorMessage(FfiError.forgedKey);
    final selfPairing = pairingErrorMessage(FfiError.selfPairing);

    expect(forged, isNot(equals(malformed)));
    expect(selfPairing, isNot(equals(malformed)));
    expect(forged, isNot(equals(selfPairing)));
  });

  test('mensagens sao unicas por variante', () {
    final messages = FfiError.values.map(pairingErrorMessage).toSet();
    expect(messages.length, FfiError.values.length);
  });
}
