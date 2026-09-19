import 'dart:typed_data';

/// Uma mensagem de sinalização recebida — payload ainda cifrado, exatamente
/// como chegou do backend (`docs/protocol.md` §8.2, sempre 1024 B).
class SignalingMessage {
  const SignalingMessage(this.topic, this.payload);

  final String topic;
  final Uint8List payload;
}

/// Interface plugável de sinalização — `docs/protocol.md` §8.3: "MQTT
/// público → relay Nostr → troca manual", nessa ordem de tentativa.
///
/// Só [MqttSignalingBackend] existe nesta fase; Nostr e a troca manual ficam
/// fora do escopo (ver relatório da Fase 3) — mas o ponto de extensão é
/// este, para não precisar tocar em quem consome [SignalingBackend] quando
/// os outros dois existirem.
abstract class SignalingBackend {
  /// Conecta ao backend. Idempotente: chamar de novo enquanto já conectado
  /// não deveria abrir uma segunda conexão.
  Future<void> connect();

  /// Assina os tópicos dados — mensagens publicadas neles passam a chegar em
  /// [incoming]. Substitui qualquer assinatura anterior deste backend: quem
  /// chama é responsável por passar a lista completa de tópicos válidos
  /// agora (ex.: a janela de três épocas de `topics_for_window`), não só os
  /// novos.
  Future<void> subscribeTopics(List<String> topics);

  /// Publica `payload` (já cifrado, ver [SignalingMessage]) no tópico dado.
  Future<void> publish(String topic, Uint8List payload);

  /// Mensagens recebidas nos tópicos assinados.
  Stream<SignalingMessage> get incoming;

  Future<void> disconnect();
}
