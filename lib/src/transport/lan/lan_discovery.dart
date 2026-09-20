import 'dart:async';

/// Um peer achado por mDNS/DNS-SD — Fase 6, F1.
class LanPeer {
  const LanPeer({required this.instanceName, required this.host, required this.port});

  /// O `beacon` em hex — nome de instância do serviço, `docs/protocol.md` §9.2.
  final String instanceName;

  /// Endereço IP (preferido) ou hostname resolvido do serviço.
  final String host;
  final int port;

  @override
  String toString() => 'LanPeer(instanceName: $instanceName, host: $host, port: $port)';
}

/// Descoberta de serviço na LAN via mDNS/DNS-SD — abstraída de
/// `package:nsd` para permitir dublê manual em teste (o pacote real faz
/// canal de plataforma, indisponível em `flutter test`).
abstract class LanDiscovery {
  /// Anuncia um serviço `_viska._tcp` com nome de instância `instanceName`,
  /// na porta `port` do `LanListener` deste processo.
  Future<void> advertise({required String instanceName, required int port});

  Future<void> stopAdvertising();

  /// Peers achados desde que [startBrowsing] foi chamado — emite um evento
  /// por serviço resolvido (host + porta já preenchidos).
  Stream<LanPeer> get discovered;

  Future<void> startBrowsing();

  Future<void> stopBrowsing();

  Future<void> close();
}
