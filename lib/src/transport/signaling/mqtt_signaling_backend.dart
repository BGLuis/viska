import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_data.dart' as typed;

import 'signaling_backend.dart';

/// `MqttSignalingBackend` — `docs/protocol.md` §8.2/§8.3, primeiro backend
/// da interface plugável.
///
/// `retain: false` e `MqttQos.atMostOnce` (QoS 0) em toda publicação — §8.2
/// exige os dois; travado aqui como argumento explícito em vez de confiar
/// só no padrão da biblioteca, e coberto por teste com um `MqttClient` fake
/// injetado (ver `test/transport/signaling/mqtt_signaling_backend_test.dart`)
/// para que uma mudança futura no valor default do pacote não passe
/// despercebida.
///
/// `autoReconnect` fica desligado de propósito: a decisão 2.3 do relatório
/// da Fase 3 exige recalcular `topics_for_window` no momento da reconexão
/// (a época pode ter virado) — uma reconexão automática da biblioteca, por
/// trás das costas, reconectaria com os tópicos antigos. Quem usa esta
/// classe chama [connect] de novo explicitamente, com tópicos recém-calculados
/// via [subscribeTopics].
class MqttSignalingBackend implements SignalingBackend {
  MqttSignalingBackend({
    String host = 'broker.emqx.io',
    String? clientIdentifier,
    MqttClient? client,
  }) : _client = client ??
            MqttServerClient(host, clientIdentifier ?? _randomClientIdentifier());

  final MqttClient _client;
  final _incoming = StreamController<SignalingMessage>.broadcast();
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSubscription;
  Set<String> _subscribedTopics = {};
  bool _connected = false;

  @override
  Stream<SignalingMessage> get incoming => _incoming.stream;

  @override
  Future<void> connect() async {
    if (_connected) return;

    _client.autoReconnect = false;
    await _client.connect();
    _updatesSubscription ??= _client.updates?.listen(_handleUpdates);
    _connected = true;
  }

  @override
  Future<void> subscribeTopics(List<String> topics) async {
    final wanted = topics.toSet();

    for (final stale in _subscribedTopics.difference(wanted)) {
      _client.unsubscribe(stale);
    }
    for (final fresh in wanted.difference(_subscribedTopics)) {
      _client.subscribe(fresh, MqttQos.atMostOnce);
    }

    _subscribedTopics = wanted;
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    final buffer = typed.Uint8Buffer()..addAll(payload);
    _client.publishMessage(topic, MqttQos.atMostOnce, buffer, retain: false);
  }

  @override
  Future<void> disconnect() async {
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    _subscribedTopics = {};
    _connected = false;
    _client.disconnect();
  }

  void _handleUpdates(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final received in messages) {
      final payload = received.payload;
      if (payload is MqttPublishMessage) {
        _incoming.add(
          SignalingMessage(received.topic, Uint8List.fromList(payload.payload.message)),
        );
      }
      // Qualquer outro tipo de pacote (SUBACK, PINGRESP, ...) chega neste
      // mesmo stream por desenho da biblioteca — não é uma mensagem de
      // aplicação, então é ignorado em vez de tratado como erro.
    }
  }

  static String _randomClientIdentifier() {
    final random = Random.secure();
    final suffix = List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
    return 'viska-$suffix';
  }
}
