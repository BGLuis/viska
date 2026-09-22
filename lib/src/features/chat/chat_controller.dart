import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

import '../../transport/lan/lan_transport.dart';
import '../../transport/multipeer/multipeer_transport.dart';
import '../../transport/p2p_transport.dart';
import '../../transport/p2p_transport_router.dart';
import '../../transport/selecting_p2p_transport.dart';
import '../../transport/webrtc_p2p_transport.dart';
import '../../transport/webrtc_transport.dart' show TransportConnectionEvent, TransportConnectionState;
import '../../transport/wifi_aware/wifi_aware_transport.dart';
import '../voice/voice_io.dart';
import 'widgets/reply_preview.dart';

/// Tipos de transporte P2P ativos para indicador visual na conversa.
enum ActiveTransportType {
  lanDirect,
  proximity,
  webRtc,
  offline,
}

extension ActiveTransportTypeExtension on ActiveTransportType {
  String get label {
    switch (this) {
      case ActiveTransportType.lanDirect:
        return '[⚡ P2P LAN Direta]';
      case ActiveTransportType.proximity:
        return '[📶 BLE Proximidade]';
      case ActiveTransportType.webRtc:
        return '[🌐 WebRTC Internet]';
      case ActiveTransportType.offline:
        return '[💤 Fila Offline]';
    }
  }
}

/// Estado e lógica de uma conversa com um contato — Fase 3, F6; nota de voz
/// (Fase 5) integrada na mesma timeline, decisão do usuário.
///
/// `ChangeNotifier` puro do Flutter, não uma lib de state management: mesmo
/// padrão do resto do projeto (`StatefulWidget` + `setState`), só que a
/// lógica fica separada da árvore de widgets para poder ser testada com
/// dublês de `Core`/`P2PTransportRouter`, sem nenhuma UI — mesmo raciocínio
/// que motivou extrair `WebrtcP2PTransport` na Fase 3, F5.
///
/// Dono de uma peça que não tinha lar em nenhuma fase anterior: decidir, a
/// cada byte cru que chega do transporte, se é uma mensagem de handshake
/// (`Core.feedHandshake`) ou um envelope de sessão já estabelecida
/// (`Core.decryptIncoming`). F5 devolve bytes crus de propósito — não sabe
/// nada de sessão viska — e a decisão de qual FFI chamar é puramente “a
/// sessão já está `Established`?”, a mesma pergunta que `Session` já resolve
/// internamente no lado Rust (`docs/protocol.md` §11.1), só que agora
/// respondida do lado Dart para saber qual método FFI chamar.
///
/// ## Nota de voz — Fase 5
///
/// `FILE_METADATA`/`FILE_FEEDBACK`/`FILE_COMPLETE` (controle da
/// transferência) já são processados como efeito colateral dentro de
/// `Core.decryptIncoming` — por isso `_handleIncomingRaw` agora sempre
/// atualiza a timeline depois de decifrar, mesmo quando o envelope não
/// produz um `IncomingMessageDto` (uma oferta de nota de voz nova, por
/// exemplo, só aparece assim). `AUDIO_CHUNK` contorna `Session` por completo
/// e chega pelo canal `file` (`incomingFileFor`), roteado sozinho pelo
/// `file_id` em claro no próprio pacote (D17) — o que permite várias
/// transferências (envio e/ou recebimento) ativas ao mesmo tempo com o
/// mesmo contato, sem que este controlador precise rastrear qual é "a"
/// transferência corrente.
class ChatController extends ChangeNotifier {
  ChatController({
    required Core core,
    required P2PTransportRouter router,
    required ContactId contactId,
    VoiceRecorder? recorder,
    VoicePlayer? player,
  })  : _core = core,
        _router = router,
        _contactId = contactId,
        _recorder = recorder ?? RecordVoiceRecorder(),
        _player = player ?? JustAudioVoicePlayer();

  final Core _core;
  final P2PTransportRouter _router;
  final ContactId _contactId;
  final VoiceRecorder _recorder;
  final VoicePlayer _player;

  List<MessageDto> _messages = [];
  List<MessageDto> get messages => List.unmodifiable(_messages);

  bool _established = false;
  bool get isEstablished => _established;

  String? _connectionError;
  String? get connectionError => _connectionError;

  bool _isVerified = false;
  bool get isVerified => _isVerified;

  bool _isKeyChanged = false;
  bool get isKeyChanged => _isKeyChanged;

  ActiveTransportType? _transportOverride;
  ActiveTransportType? get transportOverride => _transportOverride;
  set activeTransportOverride(ActiveTransportType? override) {
    _transportOverride = override;
    notifyListeners();
  }

  ActiveTransportType get activeTransport {
    if (_transportOverride != null) return _transportOverride!;
    if (!_established || _connectionError != null) {
      return ActiveTransportType.offline;
    }

    final transport = _router.transportFor(_contactId);
    if (transport == null) {
      return ActiveTransportType.offline;
    }

    P2PTransport actual = transport;
    if (actual is SelectingP2PTransport) {
      final chosen = actual.chosen;
      if (chosen == null) {
        return ActiveTransportType.offline;
      }
      actual = chosen;
    }

    if (actual is LanTransport) {
      return ActiveTransportType.lanDirect;
    } else if (actual is WifiAwareTransport || actual is MultipeerTransport) {
      return ActiveTransportType.proximity;
    } else if (actual is WebrtcP2PTransport) {
      return ActiveTransportType.webRtc;
    }

    return ActiveTransportType.webRtc;
  }

  Future<void> refreshTrustState() async {
    try {
      _isVerified = await _core.isContactVerified(contactDeviceId: _contactId.deviceId);
      _isKeyChanged = await _core.isKeyChanged(contactDeviceId: _contactId.deviceId);
      notifyListeners();
    } catch (_) {}
  }

  bool _sending = false;
  bool get isSending => _sending;

  bool _recording = false;
  bool get isRecording => _recording;

  bool _sendingVoice = false;
  bool get isSendingVoice => _sendingVoice;

  String? _voiceError;
  String? get voiceError => _voiceError;

  /// WAV já decodificado (D18) por `hex(file_id)` — de notas enviadas
  /// (cacheado ao sanitizar, antes de apagar o arquivo sanitizado) e
  /// recebidas (cacheado ao completar `_finishReceivingVoiceNote`). Uma
  /// entrada aqui é o sinal de "pronta para tocar" que a UI usa; sem
  /// entrada e `kind == VoiceNote` significa "ainda recebendo".
  final Map<String, Uint8List> _voiceNoteAudio = {};

  int? _playingMessageId;
  int? get playingMessageId => _playingMessageId;

  /// `true` se a nota de voz de `message` já está pronta para tocar —
  /// sempre `true` para uma enviada por nós (cacheada antes do envio), e
  /// só depois de completar o recebimento para uma recebida.
  bool isVoiceNoteReady(MessageDto message) {
    final fileId = message.audioFileId;
    if (fileId == null) return false;
    return _voiceNoteAudio.containsKey(_hex(fileId));
  }

  /// Retorna os bytes WAV decodificados em cache de uma nota de voz pronta.
  Uint8List? getVoiceNoteAudio(MessageDto message) {
    final fileId = message.audioFileId;
    if (fileId == null) return null;
    return _voiceNoteAudio[_hex(fileId)];
  }

  /// Reações mapeadas por ID de mensagem de destino: messageId -> { emoji: count }
  final Map<int, Map<String, int>> _reactions = {};

  /// Emojis marcados pelo usuário local: `messageId -> Set<String>`
  final Map<int, Set<String>> _userReactions = {};

  /// Mensagens de visualização única abertas nesta sessão.
  final Set<int> _openedViewOnceMessageIds = {};

  bool isViewOnceOpened(int messageId) => _openedViewOnceMessageIds.contains(messageId);

  void markViewOnceOpened(int messageId) {
    _openedViewOnceMessageIds.add(messageId);
    notifyListeners();
  }

  Map<String, int> reactionsFor(int messageId) => _reactions[messageId] ?? const {};

  Set<String> userReactionsFor(int messageId) => _userReactions[messageId] ?? const {};

  StreamSubscription<Uint8List>? _incomingSub;
  StreamSubscription<Uint8List>? _incomingFileSub;
  StreamSubscription<TransportConnectionEvent>? _connectionSub;
  var _disposed = false;

  /// Carrega o histórico, conecta o transporte (via [P2PTransportRouter],
  /// que faz isso sob demanda) e tenta publicar a mensagem de handshake se
  /// formos iniciador. Chamar uma vez, normalmente em `initState`.
  Future<void> initialize() async {
    await _refreshMessages();

    _incomingSub = _router.incomingFor(_contactId).listen(_handleIncomingRaw);
    _incomingFileSub = _router.incomingFileFor(_contactId).listen(_handleIncomingFileBytes);
    _connectionSub = _router.connectionEventsFor(_contactId).listen(_handleConnectionEvent);

    final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
    unawaited(_tryPublishOutgoingHandshake(status));
    await refreshTrustState();
  }

  /// Grava `body` como `pending` (eco otimista) e tenta enviar na hora, se a
  /// sessão já estiver pronta. Se não estiver, a mensagem fica `pending` até
  /// o handshake terminar e o outbox drenar (`_flushPending`).
  Future<void> sendText(
    String body, {
    QuotedReply? replyTo,
    bool isViewOnce = false,
  }) async {
    if (body.isEmpty) return;

    _sending = true;
    notifyListeners();
    try {
      final payload = (replyTo != null || isViewOnce)
          ? jsonEncode({
              'v': 1,
              'type': 'text',
              'text': body,
              if (replyTo != null) 'reply': replyTo.toJson(),
              if (isViewOnce) 'viewOnce': true,
            })
          : body;

      final sealed = await _core.sealOutgoingText(
        peerDeviceId: _contactId.deviceId,
        body: payload,
      );
      await _refreshMessages();
      if (sealed.bytes != null) {
        await _sendSealed(sealed.messageId, sealed.bytes!);
      }
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  /// Envia ou alterna uma reação emoji em uma mensagem de destino.
  Future<void> sendReaction({
    required int targetMessageId,
    required String emoji,
  }) async {
    final payload = jsonEncode({
      'v': 1,
      'type': 'reaction',
      'targetId': targetMessageId,
      'emoji': emoji,
    });

    final sealed = await _core.sealOutgoingText(
      peerDeviceId: _contactId.deviceId,
      body: payload,
    );
    await _refreshMessages();
    if (sealed.bytes != null) {
      await _sendSealed(sealed.messageId, sealed.bytes!);
    }
  }

  /// Cancela a gravação atual e apaga o buffer temporário imediatamente.
  Future<void> cancelRecording() async {
    if (!_recording) return;
    _recording = false;
    notifyListeners();

    try {
      final rawPath = await _recorder.stop();
      if (rawPath != null) {
        unawaited(File(rawPath).delete().catchError((_) => File(rawPath)));
      }
    } catch (_) {}
  }

  /// Pede permissão de microfone e começa a gravar em Opus — falha alto
  /// (via [voiceError]) em vez de crash se a permissão for negada ou o
  /// aparelho não suportar o codec, nunca cai em outro formato em silêncio
  /// (armadilha do relatório da Fase 5).
  Future<void> startRecording() async {
    if (_recording || _sendingVoice) return;

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      _voiceError = 'Permissão de microfone negada.';
      notifyListeners();
      return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/nota-de-voz-${DateTime.now().microsecondsSinceEpoch}.ogg';
    try {
      await _recorder.start(path);
    } catch (_) {
      _voiceError = 'Este aparelho não suporta gravação em Opus.';
      notifyListeners();
      return;
    }

    _voiceError = null;
    _recording = true;
    notifyListeners();
  }

  /// Para a gravação e manda a nota de voz pela timeline única — no-op
  /// silencioso se não havia gravação em andamento.
  Future<void> stopRecordingAndSend() async {
    if (!_recording) return;
    _recording = false;
    notifyListeners();

    final rawPath = await _recorder.stop();
    if (rawPath == null) return;

    _sendingVoice = true;
    notifyListeners();
    final sanitizedPath = '$rawPath.viska-audio';
    try {
      // Desmonta o Ogg que o gravador produziu — sanitização por subtração,
      // não filtro (Fase 5, F1, D16): o formato interno resultante não tem
      // campo algum onde `ENCODER`/`creation_time`/identificador de
      // aparelho pudessem sobreviver.
      await _core.sanitizeAndStageAudio(sourcePath: rawPath, destinationPath: sanitizedPath);
      unawaited(File(rawPath).delete().catchError((_) => File(rawPath)));

      final started = await _core.startSendAudio(
        peerDeviceId: _contactId.deviceId,
        audioPath: sanitizedPath,
        useLan: false,
      );

      // Cacheia o WAV (D18) antes de apagar o arquivo sanitizado — permite
      // tocar a própria nota enviada, sem round-trip pela rede.
      final internalBytes = await File(sanitizedPath).readAsBytes();
      final wav = await _core.decodeAudioToWav(internalBytes: internalBytes);
      _voiceNoteAudio[_hex(started.fileId)] = wav;
      unawaited(File(sanitizedPath).delete().catchError((_) => File(sanitizedPath)));

      await _refreshMessages();
      await _router.sendToContact(_contactId, started.sealedMetadata);
      await _pumpOutgoingChunks(started.fileId);
      await _core.markMessageSent(messageId: started.messageId);
      await _refreshMessages();
    } catch (_) {
      _voiceError = 'Não foi possível enviar a nota de voz.';
    } finally {
      _sendingVoice = false;
      notifyListeners();
    }
  }

  Future<void> _pumpOutgoingChunks(Uint8List fileId) async {
    while (true) {
      final chunk = await _core.nextOutgoingWireChunk(fileId: fileId);
      if (chunk == null) {
        final progress = await _core.transferProgress(fileId: fileId);
        if (progress == null || progress.isComplete) return;
        // Emissor esgotou o que tinha para o bloco atual — espera o
        // `FILE_FEEDBACK` do receptor (processado como efeito colateral
        // dentro de `Core.decryptIncoming`, já dirigido por
        // `_handleIncomingRaw`) liberar o próximo bloco. Espera curta, não
        // *polling* de descoberta — a novidade em si (oferta/conclusão) já
        // chega por evento, isto só dá ritmo ao laço de envio.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      await _router.sendFileToContact(_contactId, chunk);
    }
  }

  /// Alimenta um pacote cru do canal `file` (D17: roteia sozinho por
  /// `file_id`, em claro na frente do próprio pacote) — símbolo de arquivo
  /// genérico ou pedaço de nota de voz. `null` é normal: pacote de uma
  /// transferência que este `Core` não está rastreando (não é nosso, já
  /// terminou, etc.) — mesma política de silêncio do resto da fronteira.
  Future<void> _handleIncomingFileBytes(Uint8List wireBytes) async {
    final ingested = await _core.ingestIncomingWireBytes(wireBytes: wireBytes);
    if (ingested == null) return;
    if (ingested.progress.isComplete) {
      await _finishReceivingVoiceNote(ingested.fileId);
    }
  }

  /// Fecha um recebimento de nota de voz completo: confirma ao emissor
  /// (`FILE_COMPLETE` pelo canal `control`), decodifica para WAV (D18) e
  /// cacheia — a partir daqui [isVoiceNoteReady] passa a `true` para essa
  /// mensagem. Silencioso se `fileId` não for uma nota de voz que este
  /// controlador está rastreando (ex.: um arquivo genérico, quando essa UI
  /// existir) — `finishReceiveAudio` erra e o erro é engolido, mesma
  /// política do resto da fronteira para transferência desconhecida.
  Future<void> _finishReceivingVoiceNote(Uint8List fileId) async {
    final dir = await getTemporaryDirectory();
    final internalPath = '${dir.path}/nota-recebida-${_hex(fileId)}.viska-audio';
    try {
      final sealedComplete = await _core.finishReceiveAudio(
        peerDeviceId: _contactId.deviceId,
        fileId: fileId,
        destinationPath: internalPath,
      );
      await _router.sendToContact(_contactId, sealedComplete);

      final internalBytes = await File(internalPath).readAsBytes();
      final wav = await _core.decodeAudioToWav(internalBytes: internalBytes);
      _voiceNoteAudio[_hex(fileId)] = wav;
      notifyListeners();
    } catch (_) {
      // Não era uma transferência de áudio nossa (ou já foi concluída por
      // outro caminho) — nada a fazer.
    } finally {
      unawaited(File(internalPath).delete().catchError((_) => File(internalPath)));
    }
  }

  /// Toca uma nota de voz já pronta ([isVoiceNoteReady]) — remontagem em
  /// memória já aconteceu (D18); nada aqui grava em disco.
  Future<void> play(MessageDto message) async {
    final fileId = message.audioFileId;
    if (fileId == null) return;
    final wav = _voiceNoteAudio[_hex(fileId)];
    if (wav == null) return;

    await _player.playBytes(wav);
    _playingMessageId = message.id;
    notifyListeners();
  }

  Future<void> stopVoicePlayback() async {
    await _player.stop();
    _playingMessageId = null;
    notifyListeners();
  }

  Future<void> _handleIncomingRaw(Uint8List bytes) async {
    final status = await _core.ensureSession(peerDeviceId: _contactId.deviceId);
    final alreadyEstablished = status.state == SessionStateKind.established;

    if (!alreadyEstablished) {
      final response = await _core.feedHandshake(
        peerDeviceId: _contactId.deviceId,
        bytes: bytes,
      );
      if (response != null) {
        await _router.sendToContact(_contactId, response);
      }
      await _refreshEstablishedStateAndFlushIfNeeded();
      return;
    }

    final incoming = await _core.decryptIncoming(
      peerDeviceId: _contactId.deviceId,
      envelope: bytes,
    );
    // `isTyping`: indicador efêmero (`docs/protocol.md` §6.2), nunca
    // persistido — não vale a pena atualizar a timeline por causa dele.
    // Qualquer outro caso (mensagem de texto nova, ou `null` — AEAD falhou
    // *ou* o envelope era `FILE_METADATA`/`FILE_FEEDBACK`/`FILE_COMPLETE`,
    // processado como efeito colateral dentro de `decryptIncoming`)
    // atualiza a timeline: é assim que uma oferta de nota de voz nova
    // aparece, sem *polling*.
    if (incoming?.isTyping == true) return;
    await _refreshMessages();
  }

  void _handleConnectionEvent(TransportConnectionEvent event) {
    if (event.state == TransportConnectionState.failed) {
      _connectionError = event.reason;
      notifyListeners();
    } else if (event.state == TransportConnectionState.connected) {
      _connectionError = null;
      notifyListeners();
    }
  }

  Future<void> _tryPublishOutgoingHandshake([SessionStatusDto? currentStatus]) async {
    final status = currentStatus ?? await _core.ensureSession(peerDeviceId: _contactId.deviceId);
    if (status.state == SessionStateKind.established) {
      await _refreshEstablishedStateAndFlushIfNeeded();
      return;
    }

    final outgoing = status.outgoingHandshake;
    if (outgoing != null) {
      // `P2PTransportRouter.sendToContact` espera o canal `control` abrir de
      // verdade antes de mandar (ver `WebrtcTransport.send`, Fase 3 F3) —
      // então isto não manda a INIT cedo demais, só fica pendurado até dar.
      await _router.sendToContact(_contactId, outgoing);
    }
  }

  Future<void> _refreshEstablishedStateAndFlushIfNeeded() async {
    final status = await _core.sessionStatus(peerDeviceId: _contactId.deviceId);
    final established = status?.state == SessionStateKind.established;
    if (established && !_established) {
      _established = true;
      notifyListeners();
      await _flushPending();
    } else if (established != _established) {
      _established = established;
      notifyListeners();
    }
  }

  Future<void> _flushPending() async {
    final sealed = await _core.flushPending(peerDeviceId: _contactId.deviceId);
    for (final message in sealed) {
      final bytes = message.bytes;
      if (bytes != null) {
        await _sendSealed(message.messageId, bytes);
      }
    }
  }

  Future<void> _sendSealed(int messageId, Uint8List bytes) async {
    await _router.sendToContact(_contactId, bytes);
    await _core.markMessageSent(messageId: messageId);
    await _refreshMessages();
  }

  Future<void> _refreshMessages() async {
    final loaded = await _core.listMessages(peerDeviceId: _contactId.deviceId);
    if (_disposed) return;
    _messages = loaded;
    _aggregateReactions();
    for (final m in loaded) {
      if (m.direction == MessageDirectionDto.incoming) {
        _core.markMessageRead(messageId: m.id).catchError((_) {});
      }
    }
    notifyListeners();
  }

  void _aggregateReactions() {
    _reactions.clear();
    _userReactions.clear();

    for (final message in _messages) {
      if (message.kind != MessageKindDto.text) continue;
      final parsed = ParsedMessageContent.parse(message.body);
      if (parsed.isReaction && parsed.targetReactionId != null && parsed.reactionEmoji != null) {
        final targetId = parsed.targetReactionId!;
        final emoji = parsed.reactionEmoji!;

        final map = _reactions.putIfAbsent(targetId, () => <String, int>{});
        map[emoji] = (map[emoji] ?? 0) + 1;

        if (message.direction == MessageDirectionDto.outgoing) {
          final userSet = _userReactions.putIfAbsent(targetId, () => <String>{});
          userSet.add(emoji);
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_incomingSub?.cancel());
    unawaited(_incomingFileSub?.cancel());
    unawaited(_connectionSub?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    super.dispose();
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Conteúdo estruturado de mensagem persistida, suportando texto puro,
/// respostas citadas, reações com emojis e mensagens de visualização única.
class ParsedMessageContent {
  const ParsedMessageContent({
    required this.text,
    this.reply,
    this.isViewOnce = false,
    this.isReaction = false,
    this.targetReactionId,
    this.reactionEmoji,
  });

  final String text;
  final QuotedReply? reply;
  final bool isViewOnce;
  final bool isReaction;
  final int? targetReactionId;
  final String? reactionEmoji;

  static ParsedMessageContent parse(String rawBody) {
    if (!rawBody.startsWith('{') || !rawBody.endsWith('}')) {
      return ParsedMessageContent(text: rawBody);
    }
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is! Map<String, dynamic>) {
        return ParsedMessageContent(text: rawBody);
      }

      final type = decoded['type'] as String?;
      if (type == 'reaction') {
        return ParsedMessageContent(
          text: '',
          isReaction: true,
          targetReactionId: decoded['targetId'] as int?,
          reactionEmoji: decoded['emoji'] as String?,
        );
      }

      if (type == 'text') {
        final text = decoded['text'] as String? ?? '';
        final replyMap = decoded['reply'] as Map<String, dynamic>?;
        final reply = replyMap != null ? QuotedReply.fromJson(replyMap) : null;
        final viewOnce = decoded['viewOnce'] as bool? ?? false;
        return ParsedMessageContent(
          text: text,
          reply: reply,
          isViewOnce: viewOnce,
        );
      }

      return ParsedMessageContent(text: rawBody);
    } catch (_) {
      return ParsedMessageContent(text: rawBody);
    }
  }
}
