import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

void main() {
  group('mapIceConnectionState', () {
    test('failed produces TransportConnectionState.failed with reason', () {
      final event = mapIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );
      expect(event, isNotNull);
      expect(event!.state, TransportConnectionState.failed);
      expect(event.reason, isNotNull);
    });

    test('closed produces TransportConnectionState.closed', () {
      final event = mapIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateClosed,
      );
      expect(event, isNotNull);
      expect(event!.state, TransportConnectionState.closed);
    });

    test(
      'connected/completed do not produce event - control channel opening is the signal used for "connected", not ICE state alone',
      () {
        for (final state in [
          RTCIceConnectionState.RTCIceConnectionStateConnected,
          RTCIceConnectionState.RTCIceConnectionStateCompleted,
        ]) {
          expect(mapIceConnectionState(state), isNull, reason: '$state deveria ser null');
        }
      },
    );

    test('disconnected does not produce event - may be transient', () {
      expect(
        mapIceConnectionState(RTCIceConnectionState.RTCIceConnectionStateDisconnected),
        isNull,
      );
    });

    test('new/checking/count do not produce event', () {
      for (final state in [
        RTCIceConnectionState.RTCIceConnectionStateNew,
        RTCIceConnectionState.RTCIceConnectionStateChecking,
        RTCIceConnectionState.RTCIceConnectionStateCount,
      ]) {
        expect(mapIceConnectionState(state), isNull, reason: '$state deveria ser null');
      }
    });
  });

  group('TransportConnectionEvent', () {
    test('toString includes reason when present', () {
      const event = TransportConnectionEvent(
        TransportConnectionState.failed,
        reason: 'motivo de teste',
      );
      expect(event.toString(), contains('motivo de teste'));
      expect(event.toString(), contains('failed'));
    });

    test('toString does not include extra comma when there is no reason', () {
      const event = TransportConnectionEvent(TransportConnectionState.connected);
      expect(event.toString(), isNot(contains(',')));
    });
  });
}
