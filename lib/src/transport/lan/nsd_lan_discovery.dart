import 'dart:async';

import 'package:nsd/nsd.dart' as nsd;

import 'lan_discovery.dart';

/// Nome de serviço DNS-SD do Viska — `docs/protocol.md` §9.2. Fixo: a
/// rotação por época mora no nome de *instância* (o beacon), não no tipo de
/// serviço.
const String kViskaServiceType = '_viska._tcp';

/// Implementação de [LanDiscovery] sobre `package:nsd` — decisão de projeto
/// (não `bonsoir`), tomada explicitamente para a Fase 6.
class NsdLanDiscovery implements LanDiscovery {
  final _discoveredController = StreamController<LanPeer>.broadcast();

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  void Function(nsd.Service, nsd.ServiceStatus)? _serviceListener;

  @override
  Stream<LanPeer> get discovered => _discoveredController.stream;

  @override
  Future<void> advertise({required String instanceName, required int port}) async {
    await stopAdvertising();
    _registration = await nsd.register(
      nsd.Service(name: instanceName, type: kViskaServiceType, port: port),
    );
  }

  @override
  Future<void> stopAdvertising() async {
    final registration = _registration;
    _registration = null;
    if (registration != null) {
      try {
        await nsd.unregister(registration);
      } catch (_) {}
    }
  }

  @override
  Future<void> startBrowsing() async {
    await stopBrowsing();
    final discovery = await nsd.startDiscovery(
      kViskaServiceType,
      ipLookupType: nsd.IpLookupType.any,
    );
    _discovery = discovery;

    void listener(nsd.Service service, nsd.ServiceStatus status) {
      if (status != nsd.ServiceStatus.found) return;
      final name = service.name;
      final port = service.port;
      final addresses = service.addresses;
      final host = (addresses != null && addresses.isNotEmpty)
          ? addresses.first.address
          : service.host;
      if (name == null || port == null || host == null) return;
      _discoveredController.add(LanPeer(instanceName: name, host: host, port: port));
    }

    _serviceListener = listener;
    discovery.addServiceListener(listener);
  }

  @override
  Future<void> stopBrowsing() async {
    final discovery = _discovery;
    final listener = _serviceListener;
    _discovery = null;
    _serviceListener = null;
    if (discovery != null) {
      try {
        if (listener != null) discovery.removeServiceListener(listener);
        await nsd.stopDiscovery(discovery);
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {
    await stopAdvertising();
    await stopBrowsing();
    await _discoveredController.close();
  }
}
