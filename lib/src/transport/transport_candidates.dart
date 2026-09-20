import 'dart:io';

import 'package:viska/src/rust/ffi/core.dart';

import 'lan/lan_listener.dart';
import 'lan/lan_transport.dart';
import 'lan/nsd_lan_discovery.dart';
import 'multipeer/multipeer_transport.dart';
import 'p2p_transport.dart';
import 'webrtc_p2p_transport.dart';
import 'wifi_aware/wifi_aware_transport.dart';

/// Monta a lista de candidatos de transporte para um contato, em ordem de
/// prioridade — Fase 6, F3-F5. [SelectingP2PTransport] tenta cada um em
/// ordem e fica com o primeiro que conectar; `WebrtcP2PTransport` sempre
/// por último, como fallback garantido (não implementa `TransportReadiness`,
/// então nunca é pulado).
///
/// Wi-Fi Aware só existe no Android, MultipeerConnectivity só no iOS — o
/// `Platform.isAndroid`/`isIOS` evita sequer construir um canal de
/// plataforma que não pode funcionar naquele SO. Dentro de cada um,
/// `TransportReadiness.isLikelyReachable` (checado de forma assíncrona e
/// otimista, ver `WifiAwareTransport`/`MultipeerTransport`) ainda decide se
/// `SelectingP2PTransport` chega a tentar `connect()` de verdade.
List<P2PTransport> buildDefaultCandidates(Core core, ContactId contactId) {
  return [
    LanTransport(
      core: core,
      contactId: contactId,
      listener: LanListener.shared,
      discovery: NsdLanDiscovery(),
    ),
    if (Platform.isAndroid) WifiAwareTransport(core: core, contactId: contactId),
    if (Platform.isIOS) MultipeerTransport(core: core, contactId: contactId),
    WebrtcP2PTransport(core: core, contactId: contactId),
  ];
}
