import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
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
/// gravados no SQLite via `receiveIncoming`.
class MessageReceivedEvent extends MessageReceptionEvent {
  const MessageReceivedEvent(super.contactId, {this.message});
  final IncomingMessageDto? message;
}

/// Indicador efêmero de digitação recebido do contato.
class TypingIndicatorEvent extends MessageReceptionEvent {
  const TypingIndicatorEvent(super.contactId);
}

/// O Rust mudou o estado da sessão com o contato (handshake concluído, sessão
/// falha, limiar de renovação cruzado, sessão trocada). [state] é `null`
/// quando a sessão deixou de existir (bloqueio do cofre, re-pareamento ou
/// reset).
class SessionStateChangedEvent extends MessageReceptionEvent {
  const SessionStateChangedEvent(
    super.contactId, {
    required this.state,
    required this.needsRehandshake,
    this.generation = 0,
    this.renewing = false,
  });
  final SessionStateKind? state;
  final bool needsRehandshake;

  /// Muda quando a sessão foi trocada por outra, inclusive quando o contato
  /// reabriu e a nossa continuou `established` (docs/protocol.md §11.4). Quem
  /// dependia da sessão anterior compara este valor.
  final int generation;

  /// Uma sessão nova com o contato está sendo confirmada e segura a fila de
  /// envio (docs/protocol.md §11.4).
  final bool renewing;

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
    Duration renewalHold = defaultRenewalHold,
    Duration idleLimit = defaultIdleLimit,
  })  : _core = core,
        _renewalHold = renewalHold,
        _idleLimit = idleLimit,
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

  /// Quanto um envio ou recebimento já aceito fica sem progresso antes de o
  /// laço parar. A transferência continua no banco e volta na próxima retomada;
  /// isto só impede que um par que sumiu, ou que encerrou a transferência sem o
  /// aviso chegar (issue #108), deixe o laço rodando até o teto de 7 dias.
  static const defaultIdleLimit = Duration(minutes: 2);
  final Duration _idleLimit;

  /// Cadência de `FILE_FEEDBACK` de §7.4.
  static const _feedbackInterval = Duration(milliseconds: 500);
  final Map<String, Timer> _feedbackTimers = {};

  /// Último progresso visto por recebimento e desde quando ele não muda.
  final Map<String, ({String progress, DateTime since})> _feedbackIdle = {};
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
      generation: dto.generation,
      renewing: dto.renewing,
    );
    final previous = _sessionStates[contactId];
    final wasEstablished = previous?.isEstablished ?? false;
    _sessionStates[contactId] = event;
    _eventsController.add(event);
    // A saída só destrava quando a sessão passa a `established`, ou quando é
    // trocada por outra que já está (§11.4): antes disso o Rust devolve lista
    // vazia. Cobre também o respondedor, cuja cadeia de envio só nasce no
    // primeiro pacote recebido (§5.1).
    final renewed = previous != null && previous.generation != event.generation;
    // A retenção pode acabar sem promoção: o próximo evento depois do prazo
    // traz `renewing` falso e cancela o timer abaixo, então a drenagem fica aqui.
    final holdEnded = (previous?.renewing ?? false) && !event.renewing;
    if (event.isEstablished && (!wasEstablished || renewed || holdEnded)) {
      unawaited(_flushPending(contactId));
      // Transferências paradas por bloqueio, reinício ou troca de sessão voltam
      // a andar (docs/protocol.md §7.5). Com a sessão nova ainda segurando o
      // envio, o Rust devolve vazio e o evento da promoção chama de novo.
      if (!event.renewing) unawaited(resumeTransfers(contactId));
    }
    // O Rust não tem relógio: quando a candidata passa do prazo sem confirmar,
    // ninguém avisa. Drenar depois do prazo libera a fila pela sessão atual,
    // e a própria drenagem publica o estado novo.
    _renewalTimers.remove(contactId)?.cancel();
    if (event.renewing) {
      _renewalTimers[contactId] = Timer(_renewalHold, () {
        _renewalTimers.remove(contactId);
        if (!_disposed) unawaited(_flushPending(contactId));
      });
    }
  }

  /// Prazo de uma sessão candidata (`CANDIDATE_TIMEOUT_SECS` no Rust, 30 s)
  /// com folga de um segundo, para a drenagem cair depois dele.
  static const defaultRenewalHold = Duration(seconds: 31);
  final Duration _renewalHold;
  final Map<ContactId, Timer> _renewalTimers = {};

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

    // Anuncia a sessão assim que o canal abrir: a INIT se formos iniciador, ou
    // o sinal de reabertura se formos respondedor de uma sessão recém-aberta
    // (docs/protocol.md §11.4).
    unawaited(_publishConnectSignal(contactId));
    // Um canal novo sem troca de sessão (queda de transporte) não gera evento
    // de sessão: sem isto, o envio que parou com o canal velho só voltaria no
    // próximo bloqueio ou reabertura. Sem sessão pronta, o Rust devolve vazio.
    unawaited(resumeTransfers(contactId));
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
      // O Rust decide se os bytes são handshake, sinal de reabertura ou
      // envelope (docs/protocol.md §11.4); aqui só se devolve o que ele pedir.
      final result = await _core.receiveIncoming(
        peerDeviceId: contactId.deviceId,
        bytes: bytes,
      );
      final reply = result.reply;
      if (reply != null) {
        try {
          await _router.sendToContact(contactId, reply);
        } catch (e) {
          // Sem transporte agora: o par repete o sinal, ou `connectSignal`
          // republica quando o canal voltar.
          if (kDebugMode) debugPrint('[MessageReceptionService] Resposta a $contactId não enviada: $e');
        }
      }

      final incoming = result.message;
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

      // O feedback segue armado: se o fechamento falhar, é o tick que o tenta de
      // novo (docs/protocol.md §7.5); quando ele dá certo, o tick seguinte não
      // acha mais a transferência e para.
      if (!_feedbackTimers.containsKey(hexId)) {
        await watchIncomingTransfer(contactId, ingested.fileId);
      }
      await _finishIncoming(contactId, ingested.fileId);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Erro ao processar chunk de arquivo de $contactId: $e\n$stack');
    }
  }

  /// Recebimentos sendo fechados, por `file_id`: o último pedaço e o tick de
  /// feedback podem ver o mesmo recebimento completo, e o segundo fechamento,
  /// ao falhar, apagaria o destino que o primeiro está escrevendo.
  final Set<String> _finishing = {};

  /// Fecha um recebimento completo, onde quer que ele seja visto completo: no
  /// último pedaço, ou depois, no tick de feedback de um recebimento retomado
  /// cujo `finish` anterior falhou (docs/protocol.md §7.5).
  Future<void> _finishIncoming(ContactId contactId, Uint8List fileId) async {
    final hexId = _hex(fileId);
    if (!_finishing.add(hexId)) return;
    var committed = false;
    try {
      FileOfferDto? fileOffer;
      try {
        final fileOffers = await _core.pendingFileOffers(peerDeviceId: contactId.deviceId);
        fileOffer = fileOffers.where((o) => listEquals(o.fileId, fileId)).firstOrNull;
      } catch (_) {}
      committed = fileOffer != null
          ? await _finishReceivingFile(contactId, fileId, fileOffer)
          : await _finishReceivingVoiceNote(contactId, fileId);
    } finally {
      _finishing.remove(hexId);
      // Fechado, o feedback acaba já; senão o tick tenta de novo.
      if (committed) _stopFeedback(hexId);
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
      if (progress == null) {
        // Durante o fechamento o handle sai do mapa: ainda não acabou.
        if (!_finishing.contains(hexId)) _stopFeedback(hexId);
        return;
      }
      if (progress.isComplete) unawaited(_finishIncoming(contactId, fileId));
      final current = _progressMark(progress);
      final idle = _feedbackIdle[hexId];
      if (idle == null || idle.progress != current) {
        _feedbackIdle[hexId] = (progress: current, since: clock.now());
      } else if (clock.now().difference(idle.since) >= _idleLimit) {
        // Emissor parado: o próximo pedaço que chegar, ou a próxima retomada,
        // religa o feedback.
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
    _feedbackIdle.remove(hexId);
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

  /// `true` quando o arquivo chegou ao destino.
  Future<bool> _finishReceivingFile(
    ContactId contactId,
    Uint8List fileId,
    FileOfferDto offer,
  ) async {
    final receivedDirPath = await _getReceivedDirectory();
    final safeName = path.basename(offer.name);
    final destPath = '$receivedDirPath/viska-recv-${_hex(fileId)}-$safeName';
    final Uint8List? sealedComplete;
    try {
      sealedComplete = await _core.finishReceiveFile(
        peerDeviceId: contactId.deviceId,
        fileId: fileId,
        destinationPath: destPath,
      );
    } catch (_) {
      // Só um `Err` antes do commit chega aqui: o destino está incompleto.
      unawaited(File(destPath).delete().catchError((_) => File(destPath)));
      return false;
    }
    _receivedFilePaths[_hex(fileId)] = destPath;
    _eventsController.add(FileReceivedEvent(contactId, fileId: fileId, path: destPath));
    await _sendFileComplete(contactId, sealedComplete);
    return true;
  }

  /// `true` quando a nota chegou ao destino.
  Future<bool> _finishReceivingVoiceNote(ContactId contactId, Uint8List fileId) async {
    final receivedDirPath = await _getReceivedDirectory();
    final internalPath = '$receivedDirPath/nota-recebida-${_hex(fileId)}.viska-audio';
    try {
      final sealedComplete = await _core.finishReceiveAudio(
        peerDeviceId: contactId.deviceId,
        fileId: fileId,
        destinationPath: internalPath,
      );
      final internalBytes = await File(internalPath).readAsBytes();
      _voiceNoteAudio[_hex(fileId)] = internalBytes;
      _eventsController.add(
        VoiceNoteReceivedEvent(contactId, fileId: fileId, internalBytes: internalBytes),
      );
      await _sendFileComplete(contactId, sealedComplete);
      return true;
    } catch (_) {
      return false;
    } finally {
      unawaited(File(internalPath).delete().catchError((_) => File(internalPath)));
    }
  }

  /// O aviso de conclusão é melhor esforço: o arquivo já foi aceito, e uma
  /// falha aqui não pode desfazê-lo. Se ele se perde, o emissor só para pelo
  /// limite de inatividade (issue #108).
  Future<void> _sendFileComplete(ContactId contactId, Uint8List? sealedComplete) async {
    if (sealedComplete == null) return;
    try {
      await _router.sendToContact(contactId, sealedComplete);
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] FILE_COMPLETE a $contactId não enviado: $e');
    }
  }

  Future<void> _publishConnectSignal(ContactId contactId) async {
    try {
      final signal = await _core.connectSignal(peerDeviceId: contactId.deviceId);
      if (signal != null) {
        await _router.sendToContact(contactId, signal);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao anunciar a sessão para $contactId: $e');
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

  /// Ciclos de envio em curso, por `file_id`: a retomada e a tela de conversa
  /// podem pedir o mesmo envio, e dois ciclos mandariam cada símbolo duas vezes.
  final Map<String, _OutgoingCycle> _outgoing = {};

  /// Ciclo de um envio, igual para o que a conversa acabou de iniciar e para o
  /// retomado: entrega a oferta (a já selada em [offer], ou a que [sealOffer]
  /// selar na hora), bombeia até o emissor completar e marca a mensagem `sent`.
  /// Se parar antes disso, a mensagem vira `failed` e o erro sobe; a próxima
  /// retomada a devolve a `pending` (docs/protocol.md §7.5).
  ///
  /// O `Future` termina quando o envio completa, mas o laço segue um pouco: o
  /// receptor que retoma pode voltar a um bloco já confirmado, e o emissor que
  /// recua precisa de alguém bombeando. Ele para no `FILE_COMPLETE` ou depois do
  /// limite de inatividade, sem mexer mais na mensagem.
  ///
  /// Um pedido para um envio já em curso junta-se a ele; se trouxer
  /// [sealOffer], a oferta sai de novo mesmo assim, porque ele vem de uma
  /// retomada e o par pode tê-la perdido com a sessão anterior (o receptor
  /// ignora a cópia de uma oferta que já conhece). Segura o serviço em primeiro
  /// plano até completar, salvo com [holdForeground] falso (quem chama já
  /// segura, ou é uma nota de voz curta enviada com o app aberto).
  Future<void> runOutgoingTransfer(
    ContactId contactId,
    Uint8List fileId, {
    required int messageId,
    Uint8List? offer,
    Future<Uint8List?> Function()? sealOffer,
    bool holdForeground = true,
  }) {
    final hexId = _hex(fileId);
    final running = _outgoing[hexId];
    if (running != null) {
      if (sealOffer != null) unawaited(_sendSealedOffer(contactId, sealOffer));
      return running.done.future;
    }
    final cycle = _OutgoingCycle();
    _outgoing[hexId] = cycle;
    unawaited(_runOutgoing(
      contactId,
      fileId,
      cycle,
      messageId: messageId,
      offer: offer,
      sealOffer: sealOffer,
      holdForeground: holdForeground,
    ).whenComplete(() {
      if (identical(_outgoing[hexId], cycle)) _outgoing.remove(hexId);
    }));
    return cycle.done.future;
  }

  Future<void> _sendSealedOffer(ContactId contactId, Future<Uint8List?> Function() sealOffer) async {
    try {
      final offer = await sealOffer();
      if (offer != null) await _router.sendToContact(contactId, offer);
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Oferta retomada para $contactId não enviada: $e');
    }
  }

  Future<void> _runOutgoing(
    ContactId contactId,
    Uint8List fileId,
    _OutgoingCycle cycle, {
    required int messageId,
    required Uint8List? offer,
    required Future<Uint8List?> Function()? sealOffer,
    required bool holdForeground,
  }) async {
    var lease = holdForeground ? await _foregroundService.acquire() : null;
    Future<void> completed() async {
      if (cycle.done.isCompleted) return;
      await _core.markMessageSent(messageId: messageId);
      cycle.done.complete();
      if (!_disposed) _eventsController.add(MessageReceivedEvent(contactId));
      // O que sobra do laço só espera um eventual recuo do receptor: não vale
      // manter a notificação de envio em curso por ele.
      await lease?.release();
      lease = null;
    }

    try {
      final toSend = offer ?? await sealOffer?.call();
      if (toSend != null) await _router.sendToContact(contactId, toSend);
      await _pumpOutgoing(contactId, fileId, onComplete: completed);
      // O laço acabou sem ver o envio completo: o Rust largou o envio (recusa,
      // prazo, `FILE_COMPLETE` antes do último progresso). `mark_sent` não
      // rebaixa um estado final.
      await completed();
    } catch (e, stack) {
      if (!cycle.done.isCompleted) {
        try {
          await _core.markMessageFailed(messageId: messageId);
        } catch (e) {
          // Trancada ou banco indisponível: a abertura seguinte acerta o estado.
          if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao marcar envio $messageId como falho: $e');
        }
        cycle.done.completeError(e, stack);
      }
    } finally {
      if (!_disposed) _eventsController.add(MessageReceivedEvent(contactId));
      await lease?.release();
    }
  }

  Future<void> _pumpOutgoing(
    ContactId contactId,
    Uint8List fileId, {
    required Future<void> Function() onComplete,
  }) async {
    var completed = false;
    String? lastProgress;
    var idleSince = clock.now();
    while (true) {
      // Sair em silêncio antes de completar deixaria quem chamou marcar o envio
      // como concluído; depois de completar, sair é o fim normal.
      if (_disposed || _router.transportFor(contactId) == null) {
        if (completed) return;
        throw const TransportUnavailableException();
      }
      // Segue o transporte atual do contato: o roteador recria o canal que caiu,
      // e o emissor no Rust é o mesmo; o que se perdeu em voo o feedback pede de
      // novo.
      final chunk = await _core.nextOutgoingWireChunk(fileId: fileId);
      if (chunk != null) {
        await _router.sendFileToContact(contactId, chunk);
        idleSince = clock.now();
        continue;
      }
      final progress = await _core.transferProgress(fileId: fileId);
      if (progress == null) return;
      if (progress.isComplete && !completed) {
        completed = true;
        await onComplete();
      }
      final current = _progressMark(progress);
      if (current != lastProgress) {
        lastProgress = current;
        idleSince = clock.now();
      } else if (clock.now().difference(idleSince) >= _idleLimit) {
        if (completed) return;
        // O receptor sumiu ou já encerrou a transferência sem que o aviso
        // chegasse (issue #108). A oferta ainda sem resposta não conta: o aceite
        // de uma oferta grande espera a pessoa (§7.6).
        if (!progress.awaitingAnswer) throw const TransferStalledException();
      }
      // Emissor esgotou o que tinha para o bloco atual — espera o
      // `FILE_FEEDBACK` do receptor (processado como efeito colateral dentro de
      // `Core.receiveIncoming`, já dirigido por `_handleIncomingRaw`) liberar o
      // próximo bloco. Espera curta, não *polling* de descoberta — a novidade em
      // si (oferta/conclusão) já chega por evento, isto só dá ritmo ao laço.
      await Future<void>.delayed(completed ? const Duration(seconds: 1) : const Duration(milliseconds: 100));
    }
  }

  /// Retomadas em curso por contato: o evento de sessão e o canal novo costumam
  /// pedir a mesma retomada juntos, e elas rodam uma depois da outra.
  final Map<ContactId, Future<void>> _resumeQueue = {};

  /// Retoma as transferências com o contato (docs/protocol.md §7.5): reenvia a
  /// oferta que ainda não teve resposta, volta a bombear os envios, a mandar
  /// `FILE_FEEDBACK` dos recebimentos e entrega o aviso de um recebimento que
  /// não tinha como continuar. Pode ser chamada de novo sem efeito colateral:
  /// o Rust mantém o que já está em memória, o ciclo de envio é único por
  /// `file_id` e as chamadas para um contato não se sobrepõem.
  Future<void> resumeTransfers(ContactId contactId) {
    final previous = _resumeQueue[contactId] ?? Future<void>.value();
    final next = previous.then((_) => _resumeOnce(contactId));
    _resumeQueue[contactId] = next;
    unawaited(next.whenComplete(() {
      if (identical(_resumeQueue[contactId], next)) _resumeQueue.remove(contactId);
    }));
    return next;
  }

  Future<void> _resumeOnce(ContactId contactId) async {
    if (_isPaused || _disposed) return;
    final List<ResumedTransferDto> resumed;
    try {
      resumed = await _core.resumeTransfers(peerDeviceId: contactId.deviceId);
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao retomar transferências de $contactId: $e');
      return;
    }
    if (resumed.isEmpty || _disposed) return;
    // A mensagem do envio pode ter voltado de `failed` a `pending`.
    _eventsController.add(MessageReceivedEvent(contactId));
    for (final transfer in resumed) {
      switch (transfer.direction) {
        case ResumedDirectionDto.send:
          final messageId = transfer.messageId;
          if (messageId != null) unawaited(_resumeSend(contactId, transfer, messageId));
        case ResumedDirectionDto.receive:
          unawaited(watchIncomingTransfer(contactId, transfer.fileId));
        case ResumedDirectionDto.abandoned:
          final notice = transfer.sealedNotice;
          if (notice != null) unawaited(_sendNotice(contactId, notice));
      }
    }
  }

  Future<void> _resumeSend(ContactId contactId, ResumedTransferDto transfer, int messageId) async {
    try {
      await runOutgoingTransfer(
        contactId,
        transfer.fileId,
        messageId: messageId,
        sealOffer: transfer.needsOffer
            ? () => _core.sealResumedOffer(peerDeviceId: contactId.deviceId, fileId: transfer.fileId)
            : null,
      );
    } catch (e) {
      // A transferência continua no banco: a próxima retomada tenta de novo, até
      // concluir ou vencer o prazo de retenção.
      if (kDebugMode) debugPrint('[MessageReceptionService] Envio retomado parou para $contactId: $e');
    }
  }

  /// Melhor esforço, como a recusa de oferta: sem transporte, o aviso se perde.
  Future<void> _sendNotice(ContactId contactId, Uint8List notice) async {
    try {
      await _router.sendToContact(contactId, notice);
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Aviso a $contactId não enviado: $e');
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
    for (final timer in _renewalTimers.values) {
      timer.cancel();
    }
    _renewalTimers.clear();
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

/// Um envio em curso: [done] termina quando ele completa (ou falha antes).
class _OutgoingCycle {
  final done = Completer<void>();
}

/// O que conta como progresso para os limites de inatividade.
String _progressMark(TransferProgressDto progress) => '${progress.blocksDone}/${progress.bytesDone}';
