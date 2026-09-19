import 'dart:convert';
import 'dart:typed_data';

/// O protocolo (`docs/protocol.md` §8.2) só define o formato do envelope
/// cifrado de sinalização — não distingue oferta, resposta e candidato ICE,
/// porque os três trafegam pelo mesmo tópico e precisam de algo que os
/// diferencie do lado de dentro. Esse formato interno é conteúdo novo desta
/// implementação (Fase 3, F5), não uma tradução da spec.
enum SignalingMessageKind { offer, answer, iceCandidate }

/// Uma mensagem de sinalização decodificada — o conteúdo de dentro do
/// payload cifrado de 1024 B.
class SignalingPayload {
  const SignalingPayload._(
    this.kind, {
    this.sdp,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  factory SignalingPayload.offer(String sdp) =>
      SignalingPayload._(SignalingMessageKind.offer, sdp: sdp);

  factory SignalingPayload.answer(String sdp) =>
      SignalingPayload._(SignalingMessageKind.answer, sdp: sdp);

  factory SignalingPayload.iceCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) =>
      SignalingPayload._(
        SignalingMessageKind.iceCandidate,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
      );

  final SignalingMessageKind kind;
  final String? sdp;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  /// `byte 0 = kind`, resto é UTF-8: o SDP direto para oferta/resposta, ou
  /// um JSON pequeno para o candidato ICE (três campos, mais simples que
  /// inventar um separador binário para isso).
  Uint8List encode() {
    final Uint8List body;
    switch (kind) {
      case SignalingMessageKind.offer:
      case SignalingMessageKind.answer:
        body = Uint8List.fromList(utf8.encode(sdp ?? ''));
      case SignalingMessageKind.iceCandidate:
        body = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'candidate': candidate,
              'sdpMid': sdpMid,
              'sdpMLineIndex': sdpMLineIndex,
            }),
          ),
        );
    }
    return Uint8List.fromList([kind.index, ...body]);
  }

  /// Erra com [FormatException] em qualquer entrada que não bata com o
  /// formato — `bytes` já passou pela decifragem do AEAD (autenticado), mas
  /// isso não garante que a outra ponta fale exatamente esta versão do
  /// formato interno.
  static SignalingPayload decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('payload de sinalização vazio');
    }

    final kindIndex = bytes[0];
    if (kindIndex >= SignalingMessageKind.values.length) {
      throw FormatException(
        'tipo de mensagem de sinalização desconhecido: $kindIndex',
      );
    }
    final kind = SignalingMessageKind.values[kindIndex];
    final body = utf8.decode(bytes.sublist(1));

    switch (kind) {
      case SignalingMessageKind.offer:
        return SignalingPayload.offer(body);
      case SignalingMessageKind.answer:
        return SignalingPayload.answer(body);
      case SignalingMessageKind.iceCandidate:
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic> || decoded['candidate'] is! String) {
          throw const FormatException('candidato ICE malformado');
        }
        return SignalingPayload.iceCandidate(
          candidate: decoded['candidate'] as String,
          sdpMid: decoded['sdpMid'] as String?,
          sdpMLineIndex: decoded['sdpMLineIndex'] as int?,
        );
    }
  }
}
