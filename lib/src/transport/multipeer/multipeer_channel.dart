import 'dart:async';

import 'package:flutter/services.dart';

/// Evento vindo do canal de plataforma de MultipeerConnectivity — mesmos
/// quatro tipos de `wifi_aware_channel.dart` (a API nativa por trás é
/// diferente, mas o vocabulário do lado Dart é o mesmo nas duas).
sealed class MultipeerEvent {
  const MultipeerEvent();
}

class MultipeerServiceDiscovered extends MultipeerEvent {
  const MultipeerServiceDiscovered();
}

class MultipeerSessionEstablished extends MultipeerEvent {
  const MultipeerSessionEstablished();
}

class MultipeerDataReceived extends MultipeerEvent {
  const MultipeerDataReceived(this.bytes);
  final Uint8List bytes;
}

class MultipeerConnectionLost extends MultipeerEvent {
  const MultipeerConnectionLost(this.reason);
  final String? reason;
}

/// Interface intermediária entre `MultipeerTransport` e o canal de
/// plataforma real — mesmo raciocínio de `WifiAwareChannel`: nunca tocada
/// diretamente em teste.
abstract class MultipeerChannel {
  Future<bool> isSupported();

  /// Anuncia o beacon (hex) no `discoveryInfo` — papel passivo.
  Future<void> advertise(String beaconHex);

  /// Procura por um peer cujo `discoveryInfo["beacon"]` bata com o
  /// esperado — papel ativo.
  Future<void> browse(String beaconHex);

  Future<void> send(Uint8List bytes);

  Future<void> close();

  Stream<MultipeerEvent> get events;
}

/// Implementação concreta sobre `MethodChannel`/`EventChannel` — espelha
/// `MultipeerPlugin.swift` (Fase 6, F5). Só existe no iOS.
class MethodChannelMultipeerChannel implements MultipeerChannel {
  MethodChannelMultipeerChannel({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _method = methodChannel ?? const MethodChannel('viska/multipeer'),
        _event = eventChannel ?? const EventChannel('viska/multipeer/events');

  final MethodChannel _method;
  final EventChannel _event;
  Stream<MultipeerEvent>? _events;

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
  Future<void> advertise(String beaconHex) =>
      _method.invokeMethod<void>('advertise', {'beaconHex': beaconHex});

  @override
  Future<void> browse(String beaconHex) =>
      _method.invokeMethod<void>('browse', {'beaconHex': beaconHex});

  @override
  Future<void> send(Uint8List bytes) => _method.invokeMethod<void>('send', {'bytes': bytes});

  @override
  Future<void> close() => _method.invokeMethod<void>('close');

  @override
  Stream<MultipeerEvent> get events => _events ??= _event.receiveBroadcastStream().map(_decode);

  static MultipeerEvent _decode(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);
    return switch (map['event']) {
      'serviceDiscovered' => const MultipeerServiceDiscovered(),
      'sessionEstablished' => const MultipeerSessionEstablished(),
      'dataReceived' =>
        MultipeerDataReceived(Uint8List.fromList(List<int>.from(map['bytes'] as List))),
      'connectionLost' => MultipeerConnectionLost(map['reason'] as String?),
      _ => const MultipeerConnectionLost('evento desconhecido do canal de plataforma'),
    };
  }
}
