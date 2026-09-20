import 'dart:typed_data';

/// Formatação de `BeaconID` — `docs/protocol.md` §9. Os 16 bytes em si vêm
/// do núcleo Rust (`Core.discoveryBeacons`/`Core.matchDiscoveredBeacon`);
/// este arquivo só sabe representá-los do jeito que cada rádio espera, sem
/// nenhuma lógica de derivação.

/// Nome de instância mDNS/DNS-SD: o beacon em hexadecimal minúsculo —
/// `docs/protocol.md` §9.2.
String toHexInstanceName(Uint8List beacon) {
  final buffer = StringBuffer();
  for (final byte in beacon) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// UUID de serviço BLE de 128 bits no formato `8-4-4-4-12` — `docs/protocol.md`
/// §9.1. Exige exatamente 16 bytes, o tamanho de um UUID.
String toBleServiceUuid(Uint8List beacon) {
  if (beacon.length != 16) {
    throw ArgumentError.value(beacon.length, 'beacon.length', 'esperado 16 bytes');
  }
  final hex = toHexInstanceName(beacon);
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20, 32)}';
}
