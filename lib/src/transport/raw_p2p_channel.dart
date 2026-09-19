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

  Stream<Uint8List> get incoming;
  Stream<TransportConnectionEvent> get connectionEvents;
  Stream<RTCIceCandidate> get localIceCandidates;

  Future<void> close();
}
