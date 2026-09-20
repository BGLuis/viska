import 'package:flutter/services.dart';

import 'ble_advertiser.dart';

/// Implementação de [BleAdvertiser] sobre um canal de plataforma próprio —
/// `android/app/.../BleAdvertiserPlugin.kt` (Android, `BluetoothLeAdvertiser`)
/// e `ios/Runner/BleAdvertiser.swift` (iOS, `CBPeripheralManager`). Nenhum
/// dos dois foi exercitado em hardware real ainda (Fase 6, §5 do relatório
/// — só verificável com dois aparelhos físicos).
class BleAdvertiserChannel implements BleAdvertiser {
  BleAdvertiserChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('viska/ble_advertiser');

  final MethodChannel _channel;

  @override
  Future<bool> isSupported() async {
    final supported = await _channel.invokeMethod<bool>('isSupported');
    return supported ?? false;
  }

  @override
  Future<void> startAdvertising(String serviceUuid) async {
    await _channel.invokeMethod<void>('startAdvertising', {'serviceUuid': serviceUuid});
  }

  @override
  Future<void> stopAdvertising() async {
    await _channel.invokeMethod<void>('stopAdvertising');
  }
}
