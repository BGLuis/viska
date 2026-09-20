/// Anúncio BLE por UUID de serviço rotativo — papel periférico (Fase 6, F2).
///
/// `flutter_blue_plus` não cobre advertising de forma confiável em todas as
/// plataformas (relatório da Fase 6, §3), então esta interface é
/// implementada por um canal de plataforma próprio
/// (`ble_advertiser_channel.dart`), não por um pacote pronto.
abstract class BleAdvertiser {
  /// `false` se o aparelho/SO não suportar advertising BLE — a UI não deve
  /// apresentar erro, só deixar de oferecer o modo local por BLE
  /// (armadilha "Wi-Fi Aware tem cobertura irregular" do relatório, mesmo
  /// raciocínio se aplica aqui).
  Future<bool> isSupported();

  /// Anuncia `serviceUuid` (formato `8-4-4-4-12`, `docs/protocol.md` §9.1)
  /// no UUID de serviço do pacote de advertising — **nunca** em
  /// manufacturer data (decisão 2.2 do relatório: o iOS em segundo plano
  /// não anuncia esse campo).
  Future<void> startAdvertising(String serviceUuid);

  Future<void> stopAdvertising();
}
