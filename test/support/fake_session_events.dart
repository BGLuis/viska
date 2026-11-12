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
  var _generation = 0;
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

  int get generation => _generation;

  /// A sessão foi trocada por outra (o par reabriu, §11.4) sem mudar de estado.
  set generation(int value) {
    _generation = value;
    _emitSessionState();
  }

  void _emitSessionState() => _sessionEvents.add(_snapshot());

  SessionStateEventDto _snapshot() => SessionStateEventDto(
        peerDeviceId: Uint8List.fromList(peerDeviceId),
        state: _gone ? null : _state,
        needsRehandshake: _needsRehandshake,
        generation: _generation,
      );

  Stream<SessionStateEventDto> subscribeSessionEvents() async* {
    yield _snapshot();
    yield* _sessionEvents.stream;
  }
}

/// Reproduz, num `Core` falso, `Core.subscribeTransferEvents`: eventos de
/// oferta empurrados por [emitTransferEvent].
mixin FakeTransferEvents {
  final _transferEvents = StreamController<TransferEventDto>.broadcast(sync: true);

  void emitTransferEvent(TransferEventDto event) => _transferEvents.add(event);

  Stream<TransferEventDto> subscribeTransferEvents() => _transferEvents.stream;
}
