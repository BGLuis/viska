import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/transfer_foreground_service.dart';
import 'package:viska/src/transport/webrtc_transport.dart'
    show TransportConnectionEvent, TransportConnectionState;

/// Eventos emitidos pelo [MessageReceptionService] quando novos dados ou
/// alterações de estado ocorrem para um contato.
sealed class MessageReceptionEvent {
  const MessageReceptionEvent(this.contactId);
  final ContactId contactId;
}

/// Mensagem nova decifrada e persistida no banco, ou metadados de arquivo
/// gravados no SQLite via `decryptIncoming`.
class MessageReceivedEvent extends MessageReceptionEvent {
  const MessageReceivedEvent(super.contactId, {this.message});
  final IncomingMessageDto? message;
}

/// Indicador efêmero de digitação recebido do contato.
class TypingIndicatorEvent extends MessageReceptionEvent {
  const TypingIndicatorEvent(super.contactId);
}

/// O Rust mudou o estado da sessão com o contato (handshake concluído, sessão
/// falha, limiar de renovação cruzado). [state] é `null` quando a sessão
/// deixou de existir (bloqueio do cofre, re-pareamento ou reset).
class SessionStateChangedEvent extends MessageReceptionEvent {
  const SessionStateChangedEvent(
    super.contactId, {
    required this.state,
    required this.needsRehandshake,
  });
  final SessionStateKind? state;
  final bool needsRehandshake;

  bool get isEstablished => state == SessionStateKind.established;
}

/// O Rust avisou que uma oferta de arquivo retida para confirmação apareceu ou
/// deixou de existir. É só um aviso de "releia": o nome e o tamanho continuam
/// vindo de `unconfirmedFileOffers`, nunca do evento.
class OffersChangedEvent extends MessageReceptionEvent {
  const OffersChangedEvent(super.contactId, {required this.fileId, required this.kind});
  final Uint8List fileId;
  final TransferEventKind kind;
}

/// Arquivo genérico recebido, verificado por Merkle root e salvo em disco.
class FileReceivedEvent extends MessageReceptionEvent {
  const FileReceivedEvent(
    super.contactId, {
    required this.fileId,
    required this.path,
  });
  final Uint8List fileId;
  final String path;
}

/// Nota de voz recebida e verificada; carrega o áudio interno comprimido —
/// o WAV é decodificado sob demanda por quem for tocar.
class VoiceNoteReceivedEvent extends MessageReceptionEvent {
  const VoiceNoteReceivedEvent(
    super.contactId, {
    required this.fileId,
    required this.internalBytes,
  });
  final Uint8List fileId;
  final Uint8List internalBytes;
}

/// Serviço de recepção contínua no nível do aplicativo.
///
/// Mantém ouvintes ativos em [P2PTransportRouter] para todos os contatos
/// conhecidos ou criados sob demanda, garantindo que envelopes, handshakes e
/// símbolos de arquivo sejam sempre decifrados e persistidos no SQLite mesmo
/// que nenhuma tela de conversa esteja aberta na UI (Issue #3).
class MessageReceptionService {
  MessageReceptionService({
    required Core core,
    required P2PTransportRouter router,
    String? appDirPath,
    Future<String> Function()? tempDirProvider,
    Future<String> Function()? receivedDirProvider,
    TransferForegroundService? foregroundService,
  })  : _core = core,
        _router = router,
        _foregroundService = foregroundService ?? TransferForegroundService.shared,
        _appDirPath = appDirPath,
        _tempDirProvider = tempDirProvider,
        _receivedDirProvider = receivedDirProvider {
    // O Rust é quem sabe quando uma sessão muda de estado (inclusive sozinha,
    // pelo limiar de falhas de AEAD, §11.1). Assina já na construção: a
    // assinatura repete o estado atual de cada sessão, e o Rust guarda um só
    // destinatário, então este serviço deve ser o único a assinar.
    _sessionEventsSub = _core.subscribeSessionEvents().listen(
      _handleSessionEvent,
      onError: (Object e) {
        if (kDebugMode) debugPrint('[MessageReceptionService] Erro no stream de sessões: $e');
      },
    );
    // Mesmo contrato do stream de sessões: um só destinatário no Rust, e a
    // assinatura repete as ofertas já retidas.
    _transferEventsSub = _core.subscribeTransferEvents().listen(
      _handleTransferEvent,
      onError: (Object e) {
        if (kDebugMode) debugPrint('[MessageReceptionService] Erro no stream de transferências: $e');
      },
    );
    // Garante que qualquer transporte criado no roteador (por envio,
    // reconexão ou consulta) passe imediatamente a ser escutado por este serviço.
    _router.onTransportCreated = ensureListening;
  }

  final Core _core;
  final P2PTransportRouter _router;
  final String? _appDirPath;
  final Future<String> Function()? _tempDirProvider;
  final Future<String> Function()? _receivedDirProvider;
  final TransferForegroundService _foregroundService;

  /// Transporte ao qual a recepção de cada contato está ligada. O roteador
  /// troca o transporte de um contato quando o anterior falha, e a recepção
  /// precisa acompanhar a troca, senão as mensagens chegam num stream que
  /// ninguém escuta.
  final Map<ContactId, P2PTransport> _boundTransports = {};
  final Map<ContactId, StreamSubscription<TransportConnectionEvent>> _connectionSubs = {};
  final Map<ContactId, Timer> _retryTimers = {};

  /// Contatos cujo transporte vinculado já reportou queda e ainda não foi
  /// substituído. Só eles são recriados ao voltar para o primeiro plano: um
  /// transporte vivo não pode ser derrubado só porque o app mudou de tela.
  final Set<ContactId> _lostTransports = {};

  /// Espera antes de recriar o transporte de um contato que falhou: evita um
  /// laço apertado de reconexão quando o par está simplesmente offline.
  static const _retryDelay = Duration(seconds: 5);
  StreamSubscription<SessionStateEventDto>? _sessionEventsSub;
  StreamSubscription<TransferEventDto>? _transferEventsSub;
  final Map<ContactId, SessionStateChangedEvent> _sessionStates = {};
  final Map<ContactId, StreamSubscription<Uint8List>> _incomingSubs = {};
  final Map<ContactId, StreamSubscription<Uint8List>> _incomingFileSubs = {};

  final Map<String, Uint8List> _voiceNoteAudio = {};
  final Map<String, String> _receivedFilePaths = {};
  final Map<String, int> _lastFeedbackBlocksDone = {};

  /// Cadência de `FILE_FEEDBACK` de §7.4.
  static const _feedbackInterval = Duration(milliseconds: 500);
  final Map<String, Timer> _feedbackTimers = {};
  final Set<String> _feedbackTicksInFlight = {};

  final _eventsController = StreamController<MessageReceptionEvent>.broadcast();

  bool _isPaused = false;
  bool _disposed = false;

  /// Router gerenciado por este serviço de recepção.
  P2PTransportRouter get router => _router;

  /// Stream global de todos os eventos de recepção.
  Stream<MessageReceptionEvent> get events => _eventsController.stream;

  /// Último estado de sessão publicado pelo Rust para o contato, ou `null` se
  /// ainda não houve evento (a sessão pode nem existir).
  SessionStateChangedEvent? sessionStateFor(ContactId contactId) => _sessionStates[contactId];

  void _handleSessionEvent(SessionStateEventDto dto) {
    if (_disposed) return;
    final contactId = ContactId(dto.peerDeviceId);
    final event = SessionStateChangedEvent(
      contactId,
      state: dto.state,
      needsRehandshake: dto.needsRehandshake,
    );
    final wasEstablished = _sessionStates[contactId]?.isEstablished ?? false;
    _sessionStates[contactId] = event;
    _eventsController.add(event);
    // A saída só destrava quando a sessão passa a `established`: antes disso o
    // Rust devolve lista vazia. Cobre também o respondedor, cuja cadeia de
    // envio só nasce no primeiro pacote recebido (§5.1).
    if (event.isEstablished && !wasEstablished) {
      unawaited(_flushPending(contactId));
    }
  }

  void _handleTransferEvent(TransferEventDto dto) {
    if (_disposed) return;
    _eventsController.add(
      OffersChangedEvent(ContactId(dto.peerDeviceId), fileId: dto.fileId, kind: dto.kind),
    );
  }

  /// Stream de eventos filtrada para um contato específico.
  Stream<MessageReceptionEvent> eventsFor(ContactId contactId) =>
      _eventsController.stream.where((e) => e.contactId == contactId);

  /// Inicia o serviço e sincroniza escuta para todos os contatos pareados existentes.
  Future<void> start() async {
    await syncContacts();
  }

  /// Sincroniza a lista de contatos do banco Rust e garante escuta ativa em cada um.
  Future<void> syncContacts() async {
    if (_disposed || _isPaused) return;
    try {
      final contacts = await _core.listContacts();
      for (final contact in contacts) {
        ensureListening(ContactId(contact.deviceId));
      }
    } catch (_) {
      // Ignora falhas se o Core estiver temporariamente inacessível ou bloqueado.
    }
  }

  /// Vincula ouvintes de recepção nas streams do transporte para o contato, se
  /// ainda não estiverem ativos.
  void ensureListening(ContactId contactId) {
    if (_disposed) return;

    // Garante que o transporte exista. Se ele for criado agora, o roteador
    // chama este método de volta (onTransportCreated) e o vínculo é feito lá;
    // aqui a comparação abaixo então encontra o transporte já ligado.
    _router.incomingFor(contactId);
    final transport = _router.transportFor(contactId);
    if (transport == null || identical(_boundTransports[contactId], transport)) return;
    _boundTransports[contactId] = transport;
    _retryTimers.remove(contactId)?.cancel();
    _lostTransports.remove(contactId);
    unawaited(_incomingSubs.remove(contactId)?.cancel());
    unawaited(_incomingFileSubs.remove(contactId)?.cancel());
    unawaited(_connectionSubs.remove(contactId)?.cancel());

    _connectionSubs[contactId] = transport.connectionEvents.listen((event) {
      if (event.state == TransportConnectionState.failed ||
          event.state == TransportConnectionState.closed) {
        _lostTransports.add(contactId);
        _scheduleRetry(contactId, transport);
      }
    });

    final controlSub = _router.incomingFor(contactId).listen(
      (bytes) => _handleIncomingRaw(contactId, bytes),
      onError: (e) {
        if (kDebugMode) debugPrint('[MessageReceptionService] Erro no canal de controle de $contactId: $e');
      },
    );
    final fileSub = _router.incomingFileFor(contactId).listen(
      (bytes) => _handleIncomingFileBytes(contactId, bytes),
      onError: (e) {
        if (kDebugMode) debugPrint('[MessageReceptionService] Erro no canal de arquivo de $contactId: $e');
      },
    );

    _incomingSubs[contactId] = controlSub;
    _incomingFileSubs[contactId] = fileSub;

    // Se formos iniciador deste contato e houver handshake pendente,
    // despacha a INIT assim que o canal abrir.
    unawaited(_tryPublishOutgoingHandshake(contactId));
  }

  /// Recria o transporte de um contato depois que o atual falhou, para que o
  /// par volte a ser alcançável sem precisar reiniciar o app. Com o app
  /// bloqueado não tenta: `resume` ressincroniza todos os contatos.
  void _scheduleRetry(ContactId contactId, P2PTransport failed) {
    if (_disposed || _retryTimers.containsKey(contactId)) return;
    _retryTimers[contactId] = Timer(_retryDelay, () {
      _retryTimers.remove(contactId);
      if (_disposed || _isPaused) return;
      if (!identical(_boundTransports[contactId], failed)) return;
      ensureListening(contactId);
    });
  }

  /// Chamado quando o app volta ao primeiro plano. O sistema congela o app
  /// enquanto o seletor de arquivos (ou outra tela do sistema) está aberto e
  /// derruba os sockets; refazer a conexão aqui evita esperar o atraso de
  /// [_scheduleRetry]. Só recria o que já caiu: com a sessão intacta nada muda.
  void handleAppResumed() {
    if (_disposed || _isPaused) return;
    for (final contactId in _lostTransports.toList()) {
      _retryTimers.remove(contactId)?.cancel();
      ensureListening(contactId);
    }
  }

  Future<void> _handleIncomingRaw(ContactId contactId, Uint8List bytes) async {
    if (_isPaused || _disposed) return;
    try {
      final status = await _core.ensureSession(peerDeviceId: contactId.deviceId);
      if (status.state == SessionStateKind.failed) {
        // Nada a fazer com o pacote: só `reset_session` reabre a sessão, e quem
        // decide isso é a pessoa, pelo aviso do chat. O estado já foi publicado.
        if (kDebugMode) debugPrint('[MessageReceptionService] Pacote de $contactId descartado: sessão falha');
        return;
      }

      if (status.state != SessionStateKind.established) {
        final response = await _core.feedHandshake(
          peerDeviceId: contactId.deviceId,
          bytes: bytes,
        );
        if (response != null) {
          await _router.sendToContact(contactId, response);
        }
        return;
      }

      final incoming = await _core.decryptIncoming(
        peerDeviceId: contactId.deviceId,
        envelope: bytes,
      );

      if (incoming?.isTyping == true) {
        _eventsController.add(TypingIndicatorEvent(contactId));
      } else {
        // Envia recibo de entrega (MSG_RECEIPT) se for mensagem de texto recebida válida
        if (incoming?.messageId != null) {
          unawaited(_sendReceipt(contactId, incoming!.messageId.toString()));
        }

        // Notifica com a mensagem decifrada ou atualização de timeline (metadados
        // de arquivo salvos como efeito colateral no Rust).
        _eventsController.add(MessageReceivedEvent(contactId, message: incoming));
      }

      // Qualquer pacote decifrado pode ter criado a cadeia de envio do
      // respondedor (§5.1), o que destrava o que ele escreveu antes disso. A
      // sessão já estava estabelecida, então nenhuma transição dispara a
      // drenagem. Sem pendentes o Rust devolve lista vazia.
      await _flushPending(contactId);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Erro ao decifrar pacote de $contactId: $e\n$stack');
    }
  }

  Future<void> _sendReceipt(ContactId contactId, String targetId) async {
    try {
      final sealed = await _core.sealOutgoingReceipt(
        peerDeviceId: contactId.deviceId,
        targetId: targetId,
      );
      if (sealed.bytes != null) {
        await _router.sendToContact(contactId, sealed.bytes!);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao enviar recibo para $contactId: $e');
    }
  }

  Future<void> _handleIncomingFileBytes(ContactId contactId, Uint8List wireBytes) async {
    if (_isPaused || _disposed) return;
    try {
      final ingested = await _core.ingestIncomingWireBytes(wireBytes: wireBytes);
      if (ingested == null) return;
      _holdForegroundForReceive();

      final hexId = _hex(ingested.fileId);

      if (!ingested.progress.isComplete) {
        final currentBlocksDone = ingested.progress.blocksDone;
        final lastBlocksDone = _lastFeedbackBlocksDone[hexId] ?? 0;
        final blockCompleted = currentBlocksDone > lastBlocksDone;

        if (_feedbackTimers.containsKey(hexId)) {
          // Não espera o próximo tick para o emissor avançar de bloco (U-02).
          if (blockCompleted) await _sendFeedback(contactId, ingested.fileId);
        } else {
          await watchIncomingTransfer(contactId, ingested.fileId);
        }
        _lastFeedbackBlocksDone[hexId] = currentBlocksDone;
        return;
      }

      _stopFeedback(hexId);

      try {
        final fileOffers = await _core.pendingFileOffers(peerDeviceId: contactId.deviceId);
        final fileOffer = fileOffers.where((o) => listEquals(o.fileId, ingested.fileId)).firstOrNull;
        if (fileOffer != null) {
          await _finishReceivingFile(contactId, ingested.fileId, fileOffer);
          return;
        }
      } catch (_) {}

      await _finishReceivingVoiceNote(contactId, ingested.fileId);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Erro ao processar chunk de arquivo de $contactId: $e\n$stack');
    }
  }

  /// Manda `FILE_FEEDBACK` agora e a cada [_feedbackInterval] até o
  /// recebimento terminar (§7.4). Precisa ser independente da chegada de
  /// chunks: o emissor parado no fim do bloco só volta a emitir com feedback,
  /// e sem chunks um feedback dependente deles nunca sairia.
  Future<void> watchIncomingTransfer(ContactId contactId, Uint8List fileId) async {
    final hexId = _hex(fileId);
    if (_disposed || _feedbackTimers.containsKey(hexId)) return;
    _feedbackTimers[hexId] = Timer.periodic(
      _feedbackInterval,
      (_) => unawaited(_feedbackTick(contactId, fileId, hexId)),
    );
    await _sendFeedback(contactId, fileId);
  }

  Future<void> _feedbackTick(ContactId contactId, Uint8List fileId, String hexId) async {
    if (_isPaused || _disposed) return;
    if (!_feedbackTicksInFlight.add(hexId)) return;
    try {
      final progress = await _core.transferProgress(fileId: fileId);
      if (progress == null || progress.isComplete) {
        _stopFeedback(hexId);
        return;
      }
      // Sem transporte ativo, enviar criaria outro a cada tick e furaria o
      // intervalo de `_scheduleRetry` quando o par está offline.
      if (_router.transportFor(contactId) == null) return;
      await _sendFeedback(contactId, fileId);
    } catch (_) {
      // Sem progresso legível não há o que relatar; o próximo chunk religa o timer.
      _stopFeedback(hexId);
    } finally {
      _feedbackTicksInFlight.remove(hexId);
    }
  }

  Future<void> _sendFeedback(ContactId contactId, Uint8List fileId) async {
    try {
      final sealedFeedback = await _core.fileFeedback(
        peerDeviceId: contactId.deviceId,
        fileId: fileId,
      );
      await _router.sendToContact(contactId, sealedFeedback);
    } catch (_) {
      // Falha temporária; o próximo tick tenta de novo.
    }
  }

  void _stopFeedback(String hexId) {
    _feedbackTimers.remove(hexId)?.cancel();
    _lastFeedbackBlocksDone.remove(hexId);
    if (_feedbackTimers.isEmpty) _releaseForegroundForReceive();
  }

  /// Sem chunk novo por este tempo o recebimento é dado como parado: um emissor
  /// que sumiu não pode deixar a notificação do serviço acesa para sempre.
  static const _receiveIdleLimit = Duration(seconds: 60);
  Future<TransferLease>? _receiveLease;
  Timer? _receiveIdleTimer;

  /// Mantém o processo vivo enquanto chegam chunks. Só adianta se o serviço
  /// subir com o app visível (o Android recusa a partir do segundo plano), o
  /// que vale para um recebimento que já estava em curso.
  void _holdForegroundForReceive() {
    if (_disposed) return;
    _receiveLease ??= _foregroundService.acquire();
    _receiveIdleTimer?.cancel();
    _receiveIdleTimer = Timer(_receiveIdleLimit, _releaseForegroundForReceive);
  }

  void _releaseForegroundForReceive() {
    _receiveIdleTimer?.cancel();
    _receiveIdleTimer = null;
    final lease = _receiveLease;
    _receiveLease = null;
    if (lease != null) unawaited(lease.then((l) => l.release()));
  }

  Future<String> _getReceivedDirectory() async {
    final receivedDirProvider = _receivedDirProvider;
    if (receivedDirProvider != null) {
      final dir = await receivedDirProvider();
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      return dir;
    }
    if (_appDirPath != null) {
      final dir = '$_appDirPath/received';
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      return dir;
    }
    final tempDirProvider = _tempDirProvider;
    if (tempDirProvider != null) {
      return await tempDirProvider();
    }
    final tempDir = await getTemporaryDirectory();
    final dir = '${tempDir.path}/received';
    final d = Directory(dir);
    if (!d.existsSync()) d.createSync(recursive: true);
    return dir;
  }

  Future<void> _finishReceivingFile(
    ContactId contactId,
    Uint8List fileId,
    FileOfferDto offer,
  ) async {
    final receivedDirPath = await _getReceivedDirectory();
    final safeName = path.basename(offer.name);
    final destPath = '$receivedDirPath/viska-recv-${_hex(fileId)}-$safeName';
    try {
      final sealedComplete = await _core.finishReceiveFile(
        peerDeviceId: contactId.deviceId,
        fileId: fileId,
        destinationPath: destPath,
      );
      await _router.sendToContact(contactId, sealedComplete);
      _receivedFilePaths[_hex(fileId)] = destPath;
      _eventsController.add(FileReceivedEvent(contactId, fileId: fileId, path: destPath));
    } catch (_) {
      unawaited(File(destPath).delete().catchError((_) => File(destPath)));
    }
  }

  Future<void> _finishReceivingVoiceNote(ContactId contactId, Uint8List fileId) async {
    final receivedDirPath = await _getReceivedDirectory();
    final internalPath = '$receivedDirPath/nota-recebida-${_hex(fileId)}.viska-audio';
    try {
      final sealedComplete = await _core.finishReceiveAudio(
        peerDeviceId: contactId.deviceId,
        fileId: fileId,
        destinationPath: internalPath,
      );
      await _router.sendToContact(contactId, sealedComplete);

      final internalBytes = await File(internalPath).readAsBytes();
      _voiceNoteAudio[_hex(fileId)] = internalBytes;
      _eventsController.add(
        VoiceNoteReceivedEvent(contactId, fileId: fileId, internalBytes: internalBytes),
      );
    } catch (_) {
    } finally {
      unawaited(File(internalPath).delete().catchError((_) => File(internalPath)));
    }
  }

  Future<void> _tryPublishOutgoingHandshake(ContactId contactId) async {
    try {
      final status = await _core.ensureSession(peerDeviceId: contactId.deviceId);
      // Sessão já estabelecida: o evento do stream drena o que ficou pendente.
      if (status.state != SessionStateKind.handshaking) return;

      final outgoing = status.outgoingHandshake;
      if (outgoing != null) {
        await _router.sendToContact(contactId, outgoing);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao enviar handshake inicial para $contactId: $e');
    }
  }

  /// Reenvia um texto cuja entrega ficou incerta (`unknown`), por pedido da
  /// pessoa. A linha volta à fila com o mesmo `global_id`, então o par ignora a
  /// cópia se a primeira tinha chegado. A drenagem é a mesma de qualquer
  /// pendente; sem sessão estabelecida ela espera na fila.
  Future<void> resendUnknown(ContactId contactId, int messageId) async {
    await _core.resendUnknownMessage(messageId: messageId);
    await _flushPending(contactId);
  }

  Future<void> _flushPending(ContactId contactId) async {
    try {
      final sealed = await _core.flushPending(peerDeviceId: contactId.deviceId);
      // O Rust já marcou o lote inteiro como `Sending`: o que não sair aqui
      // precisa voltar à fila, senão fica fora dela até o app reiniciar.
      for (var i = 0; i < sealed.length; i++) {
        final bytes = sealed[i].bytes;
        // O Rust só devolve linhas com bytes, então isto não ocorre hoje.
        if (bytes == null) continue;
        try {
          await _router.sendToContact(contactId, bytes);
        } catch (_) {
          await _requeueUnsent(sealed.skip(i));
          rethrow;
        }
        try {
          await _core.markMessageSent(messageId: sealed[i].messageId);
        } catch (_) {
          // Os bytes já saíram: devolver esta à fila a enviaria duas vezes.
          await _requeueUnsent(sealed.skip(i + 1));
          rethrow;
        }
      }
      if (sealed.isNotEmpty) {
        _eventsController.add(MessageReceivedEvent(contactId));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao drenar outbox para $contactId: $e');
    }
  }

  Future<void> _requeueUnsent(Iterable<SealedMessageDto> unsent) async {
    for (final message in unsent) {
      try {
        await _core.requeueMessage(messageId: message.messageId);
      } catch (e) {
        // Fica `Sending` até a Core reabrir ou travar; só dá para registrar.
        if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao devolver ${message.messageId} à fila: $e');
      }
    }
  }

  /// Retorna o áudio interno comprimido de uma nota de voz pronta.
  Uint8List? getVoiceNoteAudio(Uint8List fileId) => _voiceNoteAudio[_hex(fileId)];

  /// Verifica se o áudio de uma nota de voz já está disponível para reprodução.
  bool isVoiceNoteReady(Uint8List fileId) => _voiceNoteAudio.containsKey(_hex(fileId));

  /// Cacheia o áudio interno comprimido de uma nota de voz gerada localmente.
  void cacheVoiceNoteAudio(Uint8List fileId, Uint8List internalBytes) {
    _voiceNoteAudio[_hex(fileId)] = internalBytes;
  }

  /// Retorna o caminho temporário de um arquivo recebido.
  String? getReceivedFilePath(Uint8List fileId) => _receivedFilePaths[_hex(fileId)];

  /// Cacheia o caminho temporário de um arquivo enviado/recebido.
  void cacheReceivedFilePath(Uint8List fileId, String path) {
    _receivedFilePaths[_hex(fileId)] = path;
  }

  /// Pausa o processamento de novos pacotes (usado durante bloqueio do cofre).
  void pause() {
    _isPaused = true;
  }

  /// Retoma o processamento e ressincroniza contatos após o desbloqueio.
  void resume() {
    _isPaused = false;
    unawaited(syncContacts());
  }

  /// Encerra as assinaturas de transporte e fecha o controlador de eventos.
  Future<void> dispose() async {
    _disposed = true;
    unawaited(_sessionEventsSub?.cancel());
    unawaited(_transferEventsSub?.cancel());
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    for (final sub in _incomingSubs.values) {
      await sub.cancel();
    }
    _incomingSubs.clear();

    for (final sub in _incomingFileSubs.values) {
      await sub.cancel();
    }
    _incomingFileSubs.clear();
    for (final timer in _feedbackTimers.values) {
      timer.cancel();
    }
    _feedbackTimers.clear();
    _lastFeedbackBlocksDone.clear();
    _releaseForegroundForReceive();
    for (final sub in _connectionSubs.values) {
      await sub.cancel();
    }
    _connectionSubs.clear();
    _boundTransports.clear();
    _lostTransports.clear();
    _sessionStates.clear();

    await _eventsController.close();
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
