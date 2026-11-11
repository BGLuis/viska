import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('security: all debugPrint calls in lib/ are protected by kDebugMode', () {
    final libDir = Directory('lib');
    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    final unprotected = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.contains('debugPrint') && !line.contains('kDebugMode')) {
          unprotected.add('${file.path}:${i + 1}: $line');
        }
      }
    }

    expect(
      unprotected,
      isEmpty,
      reason: 'debugPrint sem kDebugMode expõe dados em release (S-11)',
    );
  });
}
