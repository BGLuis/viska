import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/discovery/beacon_id.dart';

void main() {
  final beacon = Uint8List.fromList(List<int>.generate(16, (i) => i * 17 % 256));

  test('formata_16_bytes_como_hex_minusculo', () {
    final hex = toHexInstanceName(beacon);

    expect(hex.length, 32);
    expect(hex, hex.toLowerCase());
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(hex), isTrue);
  });

  test('formata_16_bytes_como_uuid_com_tracos_no_lugar_certo', () {
    final uuid = toBleServiceUuid(beacon);

    expect(uuid.length, 36);
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(uuid),
      isTrue,
    );
    expect(uuid.replaceAll('-', ''), toHexInstanceName(beacon));
  });

  test('rejeita_beacon_com_tamanho_diferente_de_16_bytes', () {
    expect(() => toBleServiceUuid(Uint8List(15)), throwsArgumentError);
  });
}
