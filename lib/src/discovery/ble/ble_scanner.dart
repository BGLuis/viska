import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Um beacon achado por BLE, já identificado pelo UUID de serviço de 16
/// bytes anunciado — `docs/protocol.md` §9.1.
class BleBeaconSighting {
  const BleBeaconSighting({required this.beacon});

  final Uint8List beacon;
}

/// Varredura por UUID de serviço rotativo — só o papel central/scanner
/// (Fase 6, F2). O papel periférico/anunciante (`BleAdvertiser`) é
/// implementado à parte porque `flutter_blue_plus` não cobre advertising de
/// forma confiável em todas as plataformas (relatório da Fase 6, §3).
abstract class BleScanner {
  /// Varre continuamente por qualquer um dos UUIDs de serviço em
  /// `serviceUuids` (a janela de três épocas, formatada como UUID de 128
  /// bits por `toBleServiceUuid`). Emite um evento por anúncio recebido.
  Stream<BleBeaconSighting> scan(List<String> serviceUuids);

  Future<void> stopScan();
}

class FlutterBluePlusScanner implements BleScanner {
  StreamSubscription<List<ScanResult>>? _sub;

  @override
  Stream<BleBeaconSighting> scan(List<String> serviceUuids) {
    final controller = StreamController<BleBeaconSighting>();
    final wanted = serviceUuids.map((uuid) => Guid(uuid)).toSet();

    _sub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        for (final uuid in result.advertisementData.serviceUuids) {
          if (wanted.contains(uuid)) {
            controller.add(BleBeaconSighting(beacon: _bytesOf(uuid)));
          }
        }
      }
    });

    unawaited(
      FlutterBluePlus.startScan(
        withServices: wanted.toList(),
        continuousUpdates: true,
      ),
    );

    controller.onCancel = () async {
      await stopScan();
    };

    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    await _sub?.cancel();
    _sub = null;
    await FlutterBluePlus.stopScan();
  }

  /// Os 16 bytes crus do UUID de serviço — para comparar/formatar do mesmo
  /// jeito que o resto da Fase 6 (`beacon_id.dart`), sem carregar `Guid`
  /// (tipo do `flutter_blue_plus`) para fora desta camada.
  static Uint8List _bytesOf(Guid uuid) => Uint8List.fromList(uuid.bytes);
}
