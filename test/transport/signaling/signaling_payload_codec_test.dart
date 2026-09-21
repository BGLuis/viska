import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/transport/signaling/signaling_payload_codec.dart';

void main() {
  group('SignalingPayload', () {
    test('offer: round-trip preserves SDP', () {
      final original = SignalingPayload.offer('v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n');
      final decoded = SignalingPayload.decode(original.encode());

      expect(decoded.kind, SignalingMessageKind.offer);
      expect(decoded.sdp, original.sdp);
    });

    test('answer: round-trip preserves SDP', () {
      final original = SignalingPayload.answer('v=0\r\no=- 2 2 IN IP4 0.0.0.0\r\n');
      final decoded = SignalingPayload.decode(original.encode());

      expect(decoded.kind, SignalingMessageKind.answer);
      expect(decoded.sdp, original.sdp);
    });

    test('ICE candidate: round-trip preserves all three fields', () {
      final original = SignalingPayload.iceCandidate(
        candidate: 'candidate:1 1 UDP 2130706431 10.0.0.1 5000 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
      );
      final decoded = SignalingPayload.decode(original.encode());

      expect(decoded.kind, SignalingMessageKind.iceCandidate);
      expect(decoded.candidate, original.candidate);
      expect(decoded.sdpMid, original.sdpMid);
      expect(decoded.sdpMLineIndex, original.sdpMLineIndex);
    });

    test('ICE candidate with null sdpMid and sdpMLineIndex', () {
      final original = SignalingPayload.iceCandidate(candidate: 'candidate:2 relay');
      final decoded = SignalingPayload.decode(original.encode());

      expect(decoded.candidate, 'candidate:2 relay');
      expect(decoded.sdpMid, isNull);
      expect(decoded.sdpMLineIndex, isNull);
    });

    test('offer with empty text still decodes (empty sdp, not null)', () {
      final original = SignalingPayload.offer('');
      final decoded = SignalingPayload.decode(original.encode());
      expect(decoded.sdp, '');
    });

    test('decode rejects empty bytes', () {
      expect(
        () => SignalingPayload.decode(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode rejects unknown kind without panicking', () {
      final bytes = Uint8List.fromList([200, 1, 2, 3]);
      expect(() => SignalingPayload.decode(bytes), throwsA(isA<FormatException>()));
    });

    test('decode of ICE candidate rejects JSON without candidate field', () {
      final bytes = Uint8List.fromList([
        SignalingMessageKind.iceCandidate.index,
        ...'{"sdpMid":"0"}'.codeUnits,
      ]);
      expect(() => SignalingPayload.decode(bytes), throwsA(isA<FormatException>()));
    });

    test('decode never throws anything other than FormatException on arbitrary input', () {
      // Bytes de qualquer tamanho e conteúdo, incluindo UTF-8 inválido —
      // este payload já passou pela autenticação do AEAD antes de chegar
      // aqui, mas isso não garante que a outra ponta fale este formato.
      final amostras = [
        Uint8List.fromList([0]),
        Uint8List.fromList([1]),
        Uint8List.fromList([2]),
        Uint8List.fromList([0, 0xFF, 0xFE, 0xFD]),
        Uint8List.fromList([2, ...'não é json'.codeUnits]),
      ];
      for (final bytes in amostras) {
        try {
          SignalingPayload.decode(bytes);
        } on FormatException {
          // esperado para várias destas amostras
        }
      }
    });
  });
}
