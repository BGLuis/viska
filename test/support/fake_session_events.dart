import 'dart:async';
import 'dart:typed_data';

import 'package:viska/src/rust/ffi/types.dart';

/// Reproduz, num `Core` falso, o contrato de `Core.subscribeSessionEvents`: o
/// Rust empurra toda mudança de estado da sessão e repete o estado atual ao
/// assinar. Atribuir a [sessionState] ou [needsRehandshake] equivale a o Rust
/// ter mudado a sessão por conta própria.
mixin FakeSessionEvents {
  /// `device_id` do contato que os eventos descrevem.
  List<int> peerDeviceId = List.filled(16, 0);

  SessionStateKind _state = SessionStateKind.handshaking;
  var _gone = false;
  var _needsRehandshake = false;
  final _sessionEvents = StreamController<SessionStateEventDto>.broadcast(sync: true);

  SessionStateKind get sessionState => _state;
  set sessionState(SessionStateKind value) {
    _state = value;
    _gone = false;
    _emitSessionState();
  }

  /// A sessão deixou de existir (bloqueio do cofre, re-pareamento, reset).
  void dropSession() {
    _gone = true;
    _emitSessionState();
  }

  bool get needsRehandshake => _needsRehandshake;
  set needsRehandshake(bool value) {
    _needsRehandshake = value;
    _emitSessionState();
  }

  void _emitSessionState() => _sessionEvents.add(_snapshot());

  SessionStateEventDto _snapshot() => SessionStateEventDto(
        peerDeviceId: Uint8List.fromList(peerDeviceId),
        state: _gone ? null : _state,
        needsRehandshake: _needsRehandshake,
      );

  Stream<SessionStateEventDto> subscribeSessionEvents() async* {
    yield _snapshot();
    yield* _sessionEvents.stream;
  }
}
