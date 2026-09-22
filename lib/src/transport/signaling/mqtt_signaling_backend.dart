import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_data.dart' as typed;

import 'proxy_config.dart';
import 'signaling_backend.dart';
import 'socks5_client.dart';

/// `MqttSignalingBackend` — `docs/protocol.md` §8.2/§8.3, primeiro backend
/// da interface plugável.
///
/// Suporta tunelamento opcional por Proxy SOCKS5 (ex.: Orbot / Tor na porta 9050).
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
    this.host = 'broker.emqx.io',
    this.port = 1883,
    String? clientIdentifier,
    MqttClient? client,
    ProxyConfig? proxyConfig,
  })  : _proxyConfig = proxyConfig,
        _client = client ??
            MqttServerClient(host, clientIdentifier ?? _randomClientIdentifier());

  final String host;
  final int port;
  final ProxyConfig? _proxyConfig;
  final MqttClient _client;
  Socks5LocalForwarder? _forwarder;
  final _incoming = StreamController<SignalingMessage>.broadcast();
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSubscription;
  Set<String> _subscribedTopics = {};
  bool _connected = false;

  /// Configuração de proxy ativa para este backend.
  ProxyConfig get proxyConfig => _proxyConfig ?? ProxyConfigStore.current;

  @override
  Stream<SignalingMessage> get incoming => _incoming.stream;

  @override
  Future<void> connect() async {
    if (_connected) return;
    final proxy = proxyConfig;
    if (proxy.enabled && _client is MqttServerClient) {
      final serverClient = _client;
      _forwarder = await Socks5LocalForwarder.start(
        config: proxy,
        targetHost: host,
        targetPort: port,
      );
      serverClient.server = '127.0.0.1';
      serverClient.port = _forwarder!.port;
    }

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
    await _forwarder?.close();
    _forwarder = null;
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
