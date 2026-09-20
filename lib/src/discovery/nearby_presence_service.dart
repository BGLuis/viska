import 'dart:async';

import 'package:viska/src/rust/ffi/core.dart';

import '../transport/p2p_transport.dart';
import 'beacon_id.dart';
import 'ble/ble_advertiser.dart';
import 'ble/ble_advertiser_channel.dart';
import 'ble/ble_scanner.dart';

/// Combina varredura + anúncio BLE com a derivação de beacon (F0) num
/// serviço de nível de app — Fase 6, F2. **Não é um [P2PTransport]**: BLE
/// não carrega dados de chat/arquivo nesta fase, só sinaliza "este contato
/// está por perto agora". `P2PTransportRouter` não depende deste serviço.
///
/// Uso típico: a UI escuta [nearby] para mostrar um indicador de "por
/// perto" e, opcionalmente, alimenta uma [LanAdvertisingPolicy] para
/// priorizar tentativas de LAN quando um contato aparece por BLE — gancho
/// de UI que esta classe deixa pronto mas não liga a nenhuma tela.
class NearbyPresenceService {
  NearbyPresenceService({required Core core, BleScanner? scanner, BleAdvertiser? advertiser})
      : _core = core,
        _scanner = scanner ?? FlutterBluePlusScanner(),
        _advertiser = advertiser ?? BleAdvertiserChannel();

  final Core _core;
  final BleScanner _scanner;
  final BleAdvertiser _advertiser;

  final _nearbyController = StreamController<ContactId>.broadcast();
  StreamSubscription<BleBeaconSighting>? _scanSub;
  Timer? _readvertiseTimer;
  List<ContactId> _contacts = [];
  bool _started = false;

  /// Contatos vistos por perto agora, um evento por avistamento (não
  /// deduplicado — quem consome decide se quer um `Set`/debounce).
  Stream<ContactId> get nearby => _nearbyController.stream;

  /// Começa a varrer pelos beacons de todos os contatos pareados, e a
  /// anunciar o beacon deste aparelho para `advertiseFor` (se informado —
  /// tipicamente o contato com quem se está conversando agora, mesmo
  /// raciocínio de `LanAdvertisingPolicy`).
  Future<void> start({required List<ContactId> contacts, ContactId? advertiseFor}) async {
    _contacts = contacts;
    if (_started) {
      await _restartScan();
      await _restartAdvertising(advertiseFor);
      return;
    }
    _started = true;
    await _restartScan();
    await _restartAdvertising(advertiseFor);
  }

  Future<void> _restartScan() async {
    await _scanSub?.cancel();
    if (_contacts.isEmpty) return;

    final beaconsByContact = <ContactId, List<String>>{};
    final allUuids = <String>[];
    for (final contact in _contacts) {
      final beacons = await _core.discoveryBeacons(peerDeviceId: contact.deviceId);
      final uuids = beacons.scanBeacons.map(toBleServiceUuid).toList();
      beaconsByContact[contact] = uuids;
      allUuids.addAll(uuids);
    }

    _scanSub = _scanner.scan(allUuids).listen((sighting) async {
      final contact = await _core.matchDiscoveredBeacon(beacon: sighting.beacon);
      if (contact == null) return;
      _nearbyController.add(ContactId(contact.deviceId));
    });
  }

  Future<void> _restartAdvertising(ContactId? advertiseFor) async {
    _readvertiseTimer?.cancel();
    await _advertiser.stopAdvertising();
    if (advertiseFor == null) return;

    if (!await _advertiser.isSupported()) return;

    Future<void> readvertise() async {
      final beacons = await _core.discoveryBeacons(peerDeviceId: advertiseFor.deviceId);
      await _advertiser.startAdvertising(toBleServiceUuid(beacons.advertiseBeacon));
    }

    await readvertise();
    // Reanuncia periodicamente para acompanhar a rotação de época
    // (`docs/protocol.md` §9.1, 1h) — um pouco mais frequente que isso para
    // nunca ficar anunciando um beacon já expirado por muito tempo.
    _readvertiseTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      unawaited(readvertise());
    });
  }

  Future<void> stop() async {
    _readvertiseTimer?.cancel();
    _readvertiseTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanner.stopScan();
    await _advertiser.stopAdvertising();
    _started = false;
  }

  Future<void> dispose() async {
    await stop();
    await _nearbyController.close();
  }
}
