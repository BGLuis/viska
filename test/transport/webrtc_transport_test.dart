import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

void main() {
  group('mapIceConnectionState', () {
    test('failed produz TransportConnectionState.failed com motivo', () {
      final event = mapIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );
      expect(event, isNotNull);
      expect(event!.state, TransportConnectionState.failed);
      expect(event.reason, isNotNull);
    });

    test('closed produz TransportConnectionState.closed', () {
      final event = mapIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateClosed,
      );
      expect(event, isNotNull);
      expect(event!.state, TransportConnectionState.closed);
    });

    test(
      'connected/completed não produzem evento — a abertura do canal control '
      'é o sinal usado para "conectado", não o estado ICE por si só',
      () {
        for (final state in [
          RTCIceConnectionState.RTCIceConnectionStateConnected,
          RTCIceConnectionState.RTCIceConnectionStateCompleted,
        ]) {
          expect(mapIceConnectionState(state), isNull, reason: '$state deveria ser null');
        }
      },
    );

    test('disconnected não produz evento — pode ser transitório', () {
      expect(
        mapIceConnectionState(RTCIceConnectionState.RTCIceConnectionStateDisconnected),
        isNull,
      );
    });

    test('new/checking/count não produzem evento', () {
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
    test('toString inclui o motivo quando presente', () {
      const event = TransportConnectionEvent(
        TransportConnectionState.failed,
        reason: 'motivo de teste',
      );
      expect(event.toString(), contains('motivo de teste'));
      expect(event.toString(), contains('failed'));
    });

    test('toString não inclui vírgula extra quando não há motivo', () {
      const event = TransportConnectionEvent(TransportConnectionState.connected);
      expect(event.toString(), isNot(contains(',')));
    });
  });
}
