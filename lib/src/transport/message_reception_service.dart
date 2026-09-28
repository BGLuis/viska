import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';

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

/// Handshake concluído e sessão promovida a `established`.
class SessionEstablishedEvent extends MessageReceptionEvent {
  const SessionEstablishedEvent(super.contactId);
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

/// Nota de voz recebida, verificada, decodificada para WAV e cacheada.
class VoiceNoteReceivedEvent extends MessageReceptionEvent {
  const VoiceNoteReceivedEvent(
    super.contactId, {
    required this.fileId,
    required this.wavBytes,
  });
  final Uint8List fileId;
  final Uint8List wavBytes;
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
    Future<String> Function()? tempDirProvider,
  })  : _core = core,
        _router = router,
        _tempDirProvider = tempDirProvider {
    // Garante que qualquer transporte criado no roteador (por envio,
    // reconexão ou consulta) passe imediatamente a ser escutado por este serviço.
    _router.onTransportCreated = ensureListening;
  }

  final Core _core;
  final P2PTransportRouter _router;
  final Future<String> Function()? _tempDirProvider;

  final Set<ContactId> _registeredContacts = {};
  final Set<ContactId> _establishedContacts = {};
  final Map<ContactId, StreamSubscription<Uint8List>> _incomingSubs = {};
  final Map<ContactId, StreamSubscription<Uint8List>> _incomingFileSubs = {};

  final Map<String, Uint8List> _voiceNoteAudio = {};
  final Map<String, String> _receivedFilePaths = {};
  final Map<String, int> _lastFeedbackBlocksDone = {};
  final Map<String, DateTime> _lastFeedbackTime = {};

  final _eventsController = StreamController<MessageReceptionEvent>.broadcast();

  bool _isPaused = false;
  bool _disposed = false;

  /// Router gerenciado por este serviço de recepção.
  P2PTransportRouter get router => _router;

  /// Stream global de todos os eventos de recepção.
  Stream<MessageReceptionEvent> get events => _eventsController.stream;

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
    if (!_registeredContacts.add(contactId)) return;

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

  Future<void> _handleIncomingRaw(ContactId contactId, Uint8List bytes) async {
    if (_isPaused || _disposed) return;
    try {
      final status = await _core.ensureSession(peerDeviceId: contactId.deviceId);
      final alreadyEstablished = status.state == SessionStateKind.established;

      if (!alreadyEstablished) {
        final response = await _core.feedHandshake(
          peerDeviceId: contactId.deviceId,
          bytes: bytes,
        );
        if (response != null) {
          await _router.sendToContact(contactId, response);
        }
        await _checkEstablishedAndFlush(contactId);
        return;
      }

      final incoming = await _core.decryptIncoming(
        peerDeviceId: contactId.deviceId,
        envelope: bytes,
      );

      if (incoming?.isTyping == true) {
        _eventsController.add(TypingIndicatorEvent(contactId));
        return;
      }

      // Notifica com a mensagem decifrada ou atualização de timeline (metadados
      // de arquivo salvos como efeito colateral no Rust).
      _eventsController.add(MessageReceivedEvent(contactId, message: incoming));
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Erro ao decifrar pacote de $contactId: $e\n$stack');
    }
  }

  Future<void> _handleIncomingFileBytes(ContactId contactId, Uint8List wireBytes) async {
    if (_isPaused || _disposed) return;
    try {
      final ingested = await _core.ingestIncomingWireBytes(wireBytes: wireBytes);
      if (ingested == null) return;

      final hexId = _hex(ingested.fileId);

      if (!ingested.progress.isComplete) {
        final currentBlocksDone = ingested.progress.blocksDone;
        final lastBlocksDone = _lastFeedbackBlocksDone[hexId] ?? 0;
        final lastTime = _lastFeedbackTime[hexId];
        final now = DateTime.now();

        // Envia FILE_FEEDBACK (§7.4, U-02):
        // 1. A cada bloco concluído (avançar o emissor para o próximo bloco).
        // 2. A cada 500 ms de transferência contínua dentro de um bloco.
        final blockCompleted = currentBlocksDone > lastBlocksDone;
        final intervalElapsed = lastTime == null || now.difference(lastTime) >= const Duration(milliseconds: 500);

        if (blockCompleted || intervalElapsed) {
          _lastFeedbackBlocksDone[hexId] = currentBlocksDone;
          _lastFeedbackTime[hexId] = now;
          try {
            final sealedFeedback = await _core.fileFeedback(
              peerDeviceId: contactId.deviceId,
              fileId: ingested.fileId,
            );
            await _router.sendToContact(contactId, sealedFeedback);
          } catch (_) {
            // Falha temporária ao enviar feedback; retransmite no próximo chunk/intervalo.
          }
        }
        return;
      }

      _lastFeedbackBlocksDone.remove(hexId);
      _lastFeedbackTime.remove(hexId);

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

  Future<void> _finishReceivingFile(
    ContactId contactId,
    Uint8List fileId,
    FileOfferDto offer,
  ) async {
    final tempDirPath = _tempDirProvider != null
        ? await _tempDirProvider()
        : (await getTemporaryDirectory()).path;
    final safeName = path.basename(offer.name);
    final destPath = '$tempDirPath/viska-recv-${_hex(fileId)}-$safeName';
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
    final tempDirPath = _tempDirProvider != null
        ? await _tempDirProvider()
        : (await getTemporaryDirectory()).path;
    final internalPath = '$tempDirPath/nota-recebida-${_hex(fileId)}.viska-audio';
    try {
      final sealedComplete = await _core.finishReceiveAudio(
        peerDeviceId: contactId.deviceId,
        fileId: fileId,
        destinationPath: internalPath,
      );
      await _router.sendToContact(contactId, sealedComplete);

      final internalBytes = await File(internalPath).readAsBytes();
      final wav = await _core.decodeAudioToWav(internalBytes: internalBytes);
      _voiceNoteAudio[_hex(fileId)] = wav;
      _eventsController.add(VoiceNoteReceivedEvent(contactId, fileId: fileId, wavBytes: wav));
    } catch (_) {
    } finally {
      unawaited(File(internalPath).delete().catchError((_) => File(internalPath)));
    }
  }

  Future<void> _tryPublishOutgoingHandshake(ContactId contactId) async {
    try {
      final status = await _core.ensureSession(peerDeviceId: contactId.deviceId);
      if (status.state == SessionStateKind.established) {
        _establishedContacts.add(contactId);
        return;
      }

      final outgoing = status.outgoingHandshake;
      if (outgoing != null) {
        await _router.sendToContact(contactId, outgoing);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao enviar handshake inicial para $contactId: $e');
    }
  }

  Future<void> _checkEstablishedAndFlush(ContactId contactId) async {
    final status = await _core.sessionStatus(peerDeviceId: contactId.deviceId);
    if (status?.state == SessionStateKind.established) {
      if (_establishedContacts.add(contactId)) {
        _eventsController.add(SessionEstablishedEvent(contactId));
        await _flushPending(contactId);
      }
    }
  }

  Future<void> _flushPending(ContactId contactId) async {
    try {
      final sealed = await _core.flushPending(peerDeviceId: contactId.deviceId);
      for (final message in sealed) {
        final bytes = message.bytes;
        if (bytes != null) {
          await _router.sendToContact(contactId, bytes);
          await _core.markMessageSent(messageId: message.messageId);
        }
      }
      if (sealed.isNotEmpty) {
        _eventsController.add(MessageReceivedEvent(contactId));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageReceptionService] Falha ao drenar outbox para $contactId: $e');
    }
  }

  /// Retorna os bytes WAV decodificados em cache de uma nota de voz pronta.
  Uint8List? getVoiceNoteAudio(Uint8List fileId) => _voiceNoteAudio[_hex(fileId)];

  /// Verifica se uma nota de voz já foi decodificada e está pronta para reprodução.
  bool isVoiceNoteReady(Uint8List fileId) => _voiceNoteAudio.containsKey(_hex(fileId));

  /// Cacheia os bytes WAV decodificados de uma nota de voz gerada localmente.
  void cacheVoiceNoteAudio(Uint8List fileId, Uint8List wav) {
    _voiceNoteAudio[_hex(fileId)] = wav;
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
    for (final sub in _incomingSubs.values) {
      await sub.cancel();
    }
    _incomingSubs.clear();

    for (final sub in _incomingFileSubs.values) {
      await sub.cancel();
    }
    _incomingFileSubs.clear();
    _lastFeedbackBlocksDone.clear();
    _lastFeedbackTime.clear();
    _registeredContacts.clear();
    _establishedContacts.clear();

    await _eventsController.close();
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
