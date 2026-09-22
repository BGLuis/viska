import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/discovery/beacon_id.dart';

void main() {
  final beacon = Uint8List.fromList(List<int>.generate(16, (i) => i * 17 % 256));

  test('formats 16 bytes as lowercase hex', () {
    final hex = toHexInstanceName(beacon);

    expect(hex.length, 32);
    expect(hex, hex.toLowerCase());
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(hex), isTrue);
  });

  test('formats 16 bytes as UUID with dashes in correct positions', () {
    final uuid = toBleServiceUuid(beacon);

    expect(uuid.length, 36);
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(uuid),
      isTrue,
    );
    expect(uuid.replaceAll('-', ''), toHexInstanceName(beacon));
  });

  test('rejects beacon with length different from 16 bytes', () {
    expect(() => toBleServiceUuid(Uint8List(0)), throwsArgumentError);
    expect(() => toBleServiceUuid(Uint8List(15)), throwsArgumentError);
    expect(() => toBleServiceUuid(Uint8List(17)), throwsArgumentError);
  });
}
