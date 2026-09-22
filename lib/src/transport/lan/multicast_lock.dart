import 'dart:io';

import 'package:flutter/services.dart';

/// Adquire e libera o [WifiManager.MulticastLock] do Android —
/// necessário para que pacotes mDNS cheguem ao processo antes de qualquer
/// browse/advertise via [NsdManager] (docs/protocol.md §9.2).
///
/// No-op em iOS e Linux: o [NetServiceBrowser] do iOS e o avahi do Linux
/// não precisam de lock. Só o Android filtra multicast por padrão.
///
/// Uso idiomático em [LanTransport.connect]:
/// ```dart
/// await MulticastLock.acquire();
/// try {
///   // ... browse/advertise mDNS ...
/// } finally {
///   await MulticastLock.release();
/// }
/// ```
class MulticastLock {
  MulticastLock._();

  static const _channel = MethodChannel('viska/multicast_lock');

  /// Adquire o lock multicast no Android.
  ///
  /// Silencia [PlatformException] intencionalmente: se o lock não puder ser
  /// adquirido (ex.: dispositivo sem Wi-Fi, permissão negada), o pior caso
  /// é o mDNS não funcionar — exatamente o que já acontecia antes desta
  /// correção. O fallback WebRTC permanece disponível.
  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('acquire');
    } on PlatformException {
      // Ignorado intencionalmente — ver doc acima.
    }
  }

  /// Libera o lock multicast no Android.
  ///
  /// Silencia [PlatformException]: se a liberação falhar o lock expira ao
  /// destruir o processo de qualquer forma, e não há estado inconsistente
  /// visível ao chamador.
  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } on PlatformException {
      // Ignorado intencionalmente — ver doc acima.
    }
  }
}
