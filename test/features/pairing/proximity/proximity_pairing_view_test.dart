import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/pairing/proximity/proximity_pairing_service.dart';
import 'package:viska/src/features/pairing/proximity/proximity_pairing_view.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';
import 'package:viska/src/rust/ffi/types.dart';

class _FakeViewCore implements Core {
  _FakeViewCore({required this.sasToReturn});
  final String sasToReturn;

  @override
  Future<Uint8List> myDeviceId() async =>
      Uint8List.fromList(List.generate(16, (i) => i));

  @override
  Future<String?> myNickname() async => 'Alice';

  @override
  Future<Uint8List> myQrPayload() async =>
      Uint8List.fromList(List.generate(145, (i) => i % 256));

  @override
  Future<String> computeSasCode({required List<int> peerPayload}) async => sasToReturn;

  @override
  Future<ContactDto> pairFromQr({required List<int> payload, String? nickname}) async {
    return ContactDto(
      deviceId: Uint8List.fromList(List.generate(16, (i) => i + 1)),
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 1000,
      nickname: nickname ?? 'Peer',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProximityPairingService extends ProximityPairingService {
  _FakeProximityPairingService({required super.core});

  final _peersSubject = StreamController<List<DiscoveredProximityPeer>>.broadcast();
  final _incomingSubject = StreamController<IncomingProximityPairingRequest>.broadcast();

  @override
  Stream<List<DiscoveredProximityPeer>> get discoveredPeers => _peersSubject.stream;

  @override
  Stream<IncomingProximityPairingRequest> get incomingRequests => _incomingSubject.stream;

  ProximityPairingConfirmation? confirmationToReturn;
  Object? errorToThrowOnConnect;
  Future<ProximityPairingConfirmation> Function(DiscoveredProximityPeer peer)? connectAndPairHandler;

  void emitPeers(List<DiscoveredProximityPeer> peers) {
    _peersSubject.add(peers);
  }

  void emitIncoming(IncomingProximityPairingRequest request) {
    _incomingSubject.add(request);
  }

  @override
  Future<void> start({String? customName}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<ProximityPairingConfirmation> connectAndPair(DiscoveredProximityPeer peer) async {
    if (connectAndPairHandler != null) {
      return connectAndPairHandler!(peer);
    }
    if (errorToThrowOnConnect != null) {
      throw errorToThrowOnConnect!;
    }
    return confirmationToReturn!;
  }

  @override
  void dispose() {
    _peersSubject.close();
    _incomingSubject.close();
  }
}

void main() {
  testWidgets('renders empty state initially and updates when peer is discovered', (tester) async {
    final core = _FakeViewCore(sasToReturn: '123456');
    final service = _FakeProximityPairingService(core: core);
    ContactDto? pairedContact;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProximityPairingView(
            core: core,
            service: service,
            onContactPaired: (c) => pairedContact = c,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Nenhum aparelho encontrado por perto'), findsOneWidget);

    // Emite um par descoberto
    service.emitPeers([
      DiscoveredProximityPeer(
        id: 'bob-peer',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: 9000,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Canal 15 • 127.0.0.1'), findsOneWidget);
    expect(pairedContact, isNull);
  });

  testWidgets('Initiator flow shows contextual title, text, SAS code and waiting state', (tester) async {
    final core = _FakeViewCore(sasToReturn: '987654');
    final service = _FakeProximityPairingService(core: core);
    ContactDto? pairedContact;

    final completerConfirm = Completer<ContactDto>();
    bool cancelCalled = false;

    service.confirmationToReturn = ProximityPairingConfirmation(
      peerName: 'Bob',
      channel: 15,
      sasCode: '987654',
      confirm: () => completerConfirm.future,
      cancel: () => cancelCalled = true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProximityPairingView(
            core: core,
            service: service,
            onContactPaired: (c) => pairedContact = c,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Emite o par
    service.emitPeers([
      DiscoveredProximityPeer(
        id: 'bob-peer',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: 9000,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    // Toca no par para iniciar pareamento
    await tester.tap(find.text('Bob'));
    await tester.pump(const Duration(milliseconds: 100));

    // Diálogo deve abrir com mensagens específicas de solicitante
    expect(find.text('Conectar com Bob'), findsOneWidget);
    expect(find.text('Solicitando conexão com Bob (Canal 15).'), findsOneWidget);
    expect(find.text('987 654'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Confirmar Pareamento'), findsOneWidget);

    // Clica em confirmar
    await tester.tap(find.text('Confirmar Pareamento'));
    await tester.pump(const Duration(milliseconds: 100));

    // Estado deve mudar para aguardando Bob
    expect(find.text('Aguardando Bob...'), findsOneWidget);

    // Simula conclusão da confirmação
    final fakeContact = ContactDto(
      deviceId: Uint8List(16),
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 1234,
      nickname: 'Bob',
    );
    completerConfirm.complete(fakeContact);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Diálogo deve ter fechado e callback acionado
    expect(find.text('Conectar com Bob'), findsNothing);
    expect(pairedContact, equals(fakeContact));
    expect(cancelCalled, isFalse);
  });

  testWidgets('Responder flow shows contextual request text and supports rejection', (tester) async {
    final core = _FakeViewCore(sasToReturn: '333444');
    final service = _FakeProximityPairingService(core: core);
    ContactDto? pairedContact;

    bool rejectCalled = false;
    final acceptCompleter = Completer<ContactDto>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProximityPairingView(
            core: core,
            service: service,
            onContactPaired: (c) => pairedContact = c,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Emite solicitação de conexão recebida
    service.emitIncoming(
      IncomingProximityPairingRequest(
        peerName: 'Carlos',
        channel: 8,
        sasCode: '333444',
        accept: () => acceptCompleter.future,
        reject: () => rejectCalled = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Diálogo de receptor deve abrir
    expect(find.text('Solicitação de Conexão'), findsOneWidget);
    expect(find.text('Carlos deseja se conectar com você (Canal 8).'), findsOneWidget);
    expect(find.text('333 444'), findsOneWidget);
    expect(find.text('Recusar'), findsOneWidget);
    expect(find.text('Confirmar Pareamento'), findsOneWidget);

    // Clica em recusar
    await tester.tap(find.text('Recusar'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(rejectCalled, isTrue);
    expect(find.text('Solicitação de Conexão'), findsNothing);
    expect(pairedContact, isNull);
  });

  testWidgets('Remote cancellation informs user in dialog', (tester) async {
    final core = _FakeViewCore(sasToReturn: '555666');
    final service = _FakeProximityPairingService(core: core);

    final cancelCompleter = Completer<void>();

    service.confirmationToReturn = ProximityPairingConfirmation(
      peerName: 'Bob',
      channel: 15,
      sasCode: '555666',
      whenCancelled: cancelCompleter.future,
      confirm: () async => throw Exception('cancelled'),
      cancel: () {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProximityPairingView(
            core: core,
            service: service,
            onContactPaired: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    service.emitPeers([
      DiscoveredProximityPeer(
        id: 'bob-peer',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: 9000,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Bob'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Conectar com Bob'), findsOneWidget);

    // Simula cancelamento remoto
    cancelCompleter.complete();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Pareamento cancelado pelo outro dispositivo.'), findsOneWidget);

    // Aguarda o timer de dismiss expirar e a rota fechar
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Conectar com Bob'), findsNothing);
  });

  testWidgets('displays friendly FfiError message inside dialog when confirm fails', (tester) async {
    final core = _FakeViewCore(sasToReturn: '777888');
    final service = _FakeProximityPairingService(core: core);

    service.confirmationToReturn = ProximityPairingConfirmation(
      peerName: 'Bob',
      channel: 15,
      sasCode: '777888',
      confirm: () async => throw FfiError.selfPairing,
      cancel: () {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProximityPairingView(
            core: core,
            service: service,
            onContactPaired: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    service.emitPeers([
      DiscoveredProximityPeer(
        id: 'bob-peer',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: 9000,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Bob'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Confirmar Pareamento'));
    await tester.pump(const Duration(milliseconds: 100));

    // Deve exibir a mensagem de selfPairing do pairingErrorMessage
    expect(
      find.text('Este é o seu próprio código — peça para a outra pessoa mostrar o dela.'),
      findsOneWidget,
    );
  });

  testWidgets('Disposing widget while connecting does not cause unhandled exceptions', (tester) async {
    final core = _FakeViewCore(sasToReturn: '111222');
    final service = _FakeProximityPairingService(core: core);
    final completer = Completer<ProximityPairingConfirmation>();

    service.confirmationToReturn = null;
    service.connectAndPairHandler = (peer) => completer.future;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProximityPairingView(
            core: core,
            service: service,
            onContactPaired: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    service.emitPeers([
      DiscoveredProximityPeer(
        id: 'bob-peer',
        name: 'Bob',
        channel: 15,
        address: InternetAddress.loopbackIPv4,
        port: 9000,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Bob'));
    await tester.pump(const Duration(milliseconds: 100));

    // Desmonta a tela durante a conexão
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump(const Duration(milliseconds: 100));

    // Completa o completer após o widget ser desmontado
    completer.complete(ProximityPairingConfirmation(
      peerName: 'Bob',
      channel: 15,
      sasCode: '111222',
      confirm: () async => throw Exception('unreachable'),
      cancel: () {},
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // Nenhum erro assíncrono deve ter sido disparado
    expect(tester.takeException(), isNull);
  });
}
