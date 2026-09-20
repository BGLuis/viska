import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceCandidate;

import 'webrtc_transport.dart' show TransportConnectionEvent;

/// Superfície que [WebrtcP2PTransport] precisa de um canal ponto-a-ponto de
/// baixo nível — extraída de [WebrtcTransport] só para permitir um dublê nos
/// testes de orquestração (oferta/resposta/ICE, decisão 2.3 de fechar a
/// sinalização ao conectar). `RTCPeerConnection` real exige canal de
/// plataforma nativo, indisponível em `flutter test`; esta interface é o que
/// torna a lógica de orquestração testável sem ele.
abstract class RawP2PChannel {
  Future<String> createOffer();
  Future<String> createAnswerForOffer(String remoteSdp);
  Future<void> applyRemoteAnswer(String remoteSdp);

  Future<void> addRemoteIceCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  });

  Future<void> send(Uint8List envelope);

  /// Como [send], mas no canal `file` — Fase 4/5: símbolos RaptorQ e pedaços
  /// de nota de voz, selados com chave própria fora do ratchet, contornando
  /// `Session` por completo (ver `viska_proto::file::transfer`, doc do
  /// módulo). Canal separado do `control` (`docs/protocol.md` §11.4).
  Future<void> sendFile(Uint8List bytes);

  Stream<Uint8List> get incoming;

  /// Bytes crus recebidos no canal `file` — símbolo ou pedaço de áudio
  /// selado, pronto para `Core.ingestIncomingFileSymbol`/
  /// `ingestIncomingAudioChunk`.
  Stream<Uint8List> get incomingFile;

  Stream<TransportConnectionEvent> get connectionEvents;
  Stream<RTCIceCandidate> get localIceCandidates;

  Future<void> close();
}
