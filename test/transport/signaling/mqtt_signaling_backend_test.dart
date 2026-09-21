import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_data.dart' as typed;
import 'package:viska/src/transport/signaling/mqtt_signaling_backend.dart';
import 'package:viska/src/transport/signaling/signaling_backend.dart';

class _PublishCall {
  _PublishCall(this.topic, this.qos, this.data, this.retain);
  final String topic;
  final MqttQos qos;
  final Uint8List data;
  final bool retain;
}

/// `MqttClient` real não conecta a lugar nenhum sem rede — este fake grava
/// exatamente o que `MqttSignalingBackend` chamou, para travar os parâmetros
/// exigidos por `docs/protocol.md` §8.2 (`retain: false`, QoS 0) por teste,
/// não só por revisão de código.
class _RecordingMqttClient extends MqttClient {
  _RecordingMqttClient() : super('unused-host', 'unused-client-id');

  final publishCalls = <_PublishCall>[];
  final subscribedTopics = <String>[];
  final unsubscribedTopics = <String>[];
  var connectCalls = 0;
  var disconnectCalls = 0;

  final _updatesController =
      StreamController<List<MqttReceivedMessage<MqttMessage>>>.broadcast();

  @override
  Future<MqttClientConnectionStatus?> connect([
    String? username,
    String? password,
  ]) async {
    connectCalls++;
    return null;
  }

  @override
  void disconnect() {
    disconnectCalls++;
  }

  @override
  Subscription? subscribe(String topic, MqttQos qosLevel) {
    subscribedTopics.add(topic);
    return null;
  }

  @override
  void unsubscribe(String topic, {expectAcknowledge = false}) {
    unsubscribedTopics.add(topic);
  }

  @override
  int publishMessage(
    String topic,
    MqttQos qualityOfService,
    typed.Uint8Buffer data, {
    bool retain = false,
  }) {
    publishCalls.add(
      _PublishCall(topic, qualityOfService, Uint8List.fromList(data), retain),
    );
    return 0;
  }

  @override
  Stream<List<MqttReceivedMessage<MqttMessage>>>? get updates =>
      _updatesController.stream;

  /// Simula uma mensagem chegando num tópico assinado.
  void emit(String topic, Uint8List payload) {
    final buffer = typed.Uint8Buffer()..addAll(payload);
    final message = MqttPublishMessage().publishData(buffer).toTopic(topic);
    _updatesController.add([MqttReceivedMessage(topic, message)]);
  }
}

void main() {
  group('MqttSignalingBackend', () {
    test('publish uses retain:false and QoS atMostOnce, always', () async {
      final client = _RecordingMqttClient();
      final backend = MqttSignalingBackend(client: client);
      await backend.connect();

      final payload = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      await backend.publish('topico-de-teste', payload);

      expect(client.publishCalls, hasLength(1));
      final call = client.publishCalls.single;
      expect(call.topic, 'topico-de-teste');
      expect(call.qos, MqttQos.atMostOnce);
      expect(call.retain, isFalse);
      expect(call.data, payload);
    });

    test('connect turns off autoReconnect before connecting', () async {
      final client = _RecordingMqttClient()..autoReconnect = true;
      final backend = MqttSignalingBackend(client: client);

      await backend.connect();

      expect(client.autoReconnect, isFalse);
      expect(client.connectCalls, 1);
    });

    test('connect is idempotent - calling twice does not reconnect', () async {
      final client = _RecordingMqttClient();
      final backend = MqttSignalingBackend(client: client);

      await backend.connect();
      await backend.connect();

      expect(client.connectCalls, 1);
    });

    test('subscribeTopics subscribes only to new topics and unsubscribes removed ones', () async {
      final client = _RecordingMqttClient();
      final backend = MqttSignalingBackend(client: client);
      await backend.connect();

      await backend.subscribeTopics(['epoca-1', 'epoca-2', 'epoca-3']);
      expect(client.subscribedTopics, unorderedEquals(['epoca-1', 'epoca-2', 'epoca-3']));
      expect(client.unsubscribedTopics, isEmpty);

      // A janela de épocas virou: 'epoca-1' saiu, 'epoca-4' entrou — decisão
      // 2.4 do relatório da Fase 3 (nunca reusar o tópico da época anterior).
      client.subscribedTopics.clear();
      await backend.subscribeTopics(['epoca-2', 'epoca-3', 'epoca-4']);

      expect(client.subscribedTopics, ['epoca-4']);
      expect(client.unsubscribedTopics, ['epoca-1']);
    });

    test('messages received on subscribed topics arrive in incoming', () async {
      final client = _RecordingMqttClient();
      final backend = MqttSignalingBackend(client: client);
      await backend.connect();
      await backend.subscribeTopics(['topico-a']);

      final received = <SignalingMessage>[];
      final subscription = backend.incoming.listen(received.add);

      final payload = Uint8List.fromList(List.filled(1024, 0xAB));
      client.emit('topico-a', payload);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.topic, 'topico-a');
      expect(received.single.payload, payload);

      await subscription.cancel();
    });

    test('disconnect cancels updates subscription and disconnects client', () async {
      final client = _RecordingMqttClient();
      final backend = MqttSignalingBackend(client: client);
      await backend.connect();
      await backend.subscribeTopics(['topico-a']);

      await backend.disconnect();

      expect(client.disconnectCalls, 1);

      // Depois de `disconnect`, uma mensagem emitida pelo client não deveria
      // mais chegar em `incoming` — a assinatura foi cancelada.
      final received = <SignalingMessage>[];
      final subscription = backend.incoming.listen(received.add);
      client.emit('topico-a', Uint8List(1024));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      await subscription.cancel();
    });
  });
}
