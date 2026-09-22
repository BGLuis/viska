import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/transport/lan/lan_transport.dart';
import 'package:viska/src/transport/multipeer/multipeer_transport.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/transport_candidates.dart';
import 'package:viska/src/transport/webrtc_p2p_transport.dart';
import 'package:viska/src/transport/wifi_aware/wifi_aware_transport.dart';

class _FakeCore implements Core {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('buildDefaultCandidates orders candidates by priority with WebRTC fallback last', () {
    final core = _FakeCore();
    final contactId = ContactId([1, 2, 3, 4]);

    final candidates = buildDefaultCandidates(core, contactId);

    // Deve haver ao menos LanTransport e WebrtcP2PTransport
    expect(candidates.length, greaterThanOrEqualTo(2));

    // Primeiro transporte é LanTransport (rede local sem intermediário)
    expect(candidates.first, isA<LanTransport>());

    // Último transporte é sempre WebrtcP2PTransport (fallback via sinalização)
    expect(candidates.last, isA<WebrtcP2PTransport>());

    // Valida especificidades de plataforma
    if (Platform.isAndroid) {
      expect(candidates.any((c) => c is WifiAwareTransport), isTrue);
      expect(candidates.any((c) => c is MultipeerTransport), isFalse);
    } else if (Platform.isIOS) {
      expect(candidates.any((c) => c is MultipeerTransport), isTrue);
      expect(candidates.any((c) => c is WifiAwareTransport), isFalse);
    } else {
      expect(candidates.any((c) => c is WifiAwareTransport), isFalse);
      expect(candidates.any((c) => c is MultipeerTransport), isFalse);
    }
  });
}
