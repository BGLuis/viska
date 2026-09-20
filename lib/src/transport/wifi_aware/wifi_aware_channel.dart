import 'dart:async';

import 'package:flutter/services.dart';

/// Evento vindo do canal de plataforma de Wi-Fi Aware — espelha os quatro
/// tipos que `WifiAwarePlugin.kt` emite pelo `EventChannel`.
sealed class WifiAwareEvent {
  const WifiAwareEvent();
}

class WifiAwareServiceDiscovered extends WifiAwareEvent {
  const WifiAwareServiceDiscovered();
}

class WifiAwareSessionEstablished extends WifiAwareEvent {
  const WifiAwareSessionEstablished();
}

class WifiAwareDataReceived extends WifiAwareEvent {
  const WifiAwareDataReceived(this.bytes);
  final Uint8List bytes;
}

class WifiAwareConnectionLost extends WifiAwareEvent {
  const WifiAwareConnectionLost(this.reason);
  final String? reason;
}

/// Interface intermediária entre `WifiAwareTransport` e o canal de
/// plataforma real — extraída para que os testes nunca precisem tocar
/// `MethodChannel`/`EventChannel` de verdade (indisponíveis em
/// `flutter test`), mesmo raciocínio de `RawP2PChannel`.
abstract class WifiAwareChannel {
  Future<bool> isSupported();

  /// Publica `serviceName` (o beacon em hex, mesma convenção do nome de
  /// instância mDNS) — papel passivo.
  Future<void> publish(String serviceName);

  /// Assina `serviceName` — papel ativo.
  Future<void> subscribe(String serviceName);

  Future<void> send(Uint8List bytes);

  Future<void> close();

  Stream<WifiAwareEvent> get events;
}

/// Implementação concreta sobre `MethodChannel`/`EventChannel` — espelha
/// `WifiAwarePlugin.kt` (Fase 6, F4). Só existe no Android; em qualquer
/// outra plataforma o canal simplesmente não foi registrado, e cada
/// chamada devolve `MissingPluginException`, tratada como "não suportado"
/// (nunca propagada como falha alta) por quem consome.
class MethodChannelWifiAwareChannel implements WifiAwareChannel {
  MethodChannelWifiAwareChannel({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _method = methodChannel ?? const MethodChannel('viska/wifi_aware'),
        _event = eventChannel ?? const EventChannel('viska/wifi_aware/events');

  final MethodChannel _method;
  final EventChannel _event;
  Stream<WifiAwareEvent>? _events;

  @override
  Future<bool> isSupported() async {
    try {
      final supported = await _method.invokeMethod<bool>('isSupported');
      return supported ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> publish(String serviceName) =>
      _method.invokeMethod<void>('publish', {'serviceName': serviceName});

  @override
  Future<void> subscribe(String serviceName) =>
      _method.invokeMethod<void>('subscribe', {'serviceName': serviceName});

  @override
  Future<void> send(Uint8List bytes) => _method.invokeMethod<void>('send', {'bytes': bytes});

  @override
  Future<void> close() => _method.invokeMethod<void>('close');

  @override
  Stream<WifiAwareEvent> get events =>
      _events ??= _event.receiveBroadcastStream().map(_decode);

  static WifiAwareEvent _decode(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);
    return switch (map['event']) {
      'serviceDiscovered' => const WifiAwareServiceDiscovered(),
      'sessionEstablished' => const WifiAwareSessionEstablished(),
      'dataReceived' => WifiAwareDataReceived(Uint8List.fromList(List<int>.from(map['bytes'] as List))),
      'connectionLost' => WifiAwareConnectionLost(map['reason'] as String?),
      _ => const WifiAwareConnectionLost('evento desconhecido do canal de plataforma'),
    };
  }
}
