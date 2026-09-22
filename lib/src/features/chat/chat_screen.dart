import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

import '../../transport/p2p_transport.dart';
import '../../transport/p2p_transport_router.dart';
import '../pairing/widgets/safety_number_qr_dialog.dart';
import '../pairing/widgets/safety_number_view.dart';
import 'chat_controller.dart';
import 'widgets/audio_waveform_player.dart';
import 'widgets/reaction_picker.dart';
import 'widgets/reply_preview.dart';
import 'widgets/swipe_to_reply.dart';

/// Tela de chat segura 1:1 com criptografia híbrida pós-quântica,
/// tema Dark-Tech Editorial, waveform interativo, swipe-to-reply,
/// reações com emojis e mensagens de visualização única autodestrutivas.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.core,
    required this.router,
    required this.contactId,
    this.contactLabel,
  });

  final Core core;
  final P2PTransportRouter router;
  final ContactId contactId;
  final String? contactLabel;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _controller;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  int _ephemeralTtlSecs = 0;
  late String? _currentContactLabel = widget.contactLabel;

  // Estado para resposta citada (swipe-to-reply)
  QuotedReply? _replyingTo;

  // Alternador de Visualização Única (View-Once)
  bool _isViewOnce = false;

  // Gestos avançados do microfone (trava de gravação e cancelamento)
  bool _isMicLocked = false;
  double _micDragAccumulatedX = 0.0;
  double _micDragAccumulatedY = 0.0;
  Timer? _recordTimer;
  int _recordSeconds = 0;

  @override
  void initState() {
    super.initState();
    _controller = ChatController(
      core: widget.core,
      router: widget.router,
      contactId: widget.contactId,
    );
    _controller.addListener(_onControllerChanged);
    _controller.initialize();
    _loadEphemeralTtl();
  }

  Future<void> _loadEphemeralTtl() async {
    try {
      final ttl = await widget.core.getEphemeralTtl(
        contactDeviceId: widget.contactId.deviceId,
      );
      if (mounted) {
        setState(() => _ephemeralTtlSecs = ttl);
      }
    } catch (_) {}
  }

  Future<void> _showEphemeralDialog() async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Mensagens temporárias'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: const Text('Desativado (permanentes)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 3600),
            child: const Text('1 hora'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 86400),
            child: const Text('24 horas'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 604800),
            child: const Text('7 dias'),
          ),
        ],
      ),
    );
    if (chosen != null) {
      try {
        await widget.core.setEphemeralTtl(
          contactDeviceId: widget.contactId.deviceId,
          ttlSecs: chosen,
        );
        if (mounted) {
          setState(() => _ephemeralTtlSecs = chosen);
        }
      } catch (_) {}
    }
  }

  Future<ContactDto> _resolveContact() async {
    try {
      final contacts = await widget.core.listContacts();
      for (final c in contacts) {
        if (listEquals(c.deviceId, widget.contactId.deviceId)) {
          return c;
        }
      }
    } catch (_) {}
    return ContactDto(
      deviceId: widget.contactId.deviceId,
      signingPubkey: Uint8List(32),
      dhPubkey: Uint8List(32),
      pairedAtUnixSecs: 0,
      nickname: _currentContactLabel,
      isVerified: _controller.isVerified,
    );
  }

  Future<void> _showSafetyNumberDialog() async {
    final contact = await _resolveContact();
    final safetyNumber = await widget.core.safetyNumber(
      contactDeviceId: widget.contactId.deviceId,
    );
    if (!mounted) return;

    await showDialog<bool>(
      context: context,
      builder: (_) => SafetyNumberQrDialog(
        contact: contact,
        safetyNumber: safetyNumber,
        core: widget.core,
        onVerified: () {
          _controller.refreshTrustState();
        },
      ),
    );
    await _controller.refreshTrustState();
  }

  Future<void> _showContactDetails() async {
    final safetyNumber = await widget.core.safetyNumber(
      contactDeviceId: widget.contactId.deviceId,
    );
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: CircleAvatar(
                      radius: 32,
                      backgroundColor: DarkTechTheme.primary.withValues(alpha: 0.15),
                      child: Text(
                        (_currentContactLabel?.isNotEmpty == true)
                            ? _currentContactLabel!.substring(0, 1).toUpperCase()
                            : '?',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: DarkTechTheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          _currentContactLabel ?? 'Contato sem apelido',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: DarkTechTheme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_controller.isVerified) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.verified,
                          color: Color(0xFF00E599),
                          size: 20,
                        ),
                      ],
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20, color: DarkTechTheme.primary),
                        tooltip: 'Editar apelido',
                        onPressed: () async {
                          final controller = TextEditingController(text: _currentContactLabel ?? '');
                          final newName = await showDialog<String>(
                            context: context,
                            builder: (dCtx) => AlertDialog(
                              title: const Text('Editar apelido'),
                              content: TextField(
                                controller: controller,
                                autofocus: true,
                                decoration: const InputDecoration(
                                  labelText: 'Apelido do contato',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dCtx),
                                  child: const Text('Cancelar'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(dCtx, controller.text.trim()),
                                  child: const Text('Salvar'),
                                ),
                              ],
                            ),
                          );
                          if (newName != null && newName.isNotEmpty) {
                            await widget.core.setContactNickname(
                              contactDeviceId: widget.contactId.deviceId,
                              nickname: newName,
                            );
                            if (!mounted) return;
                            setState(() => _currentContactLabel = newName);
                            setModalState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: DarkTechTheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: DarkTechTheme.divider),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.shield_outlined, color: DarkTechTheme.primary),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Criptografia Híbrida Pós-Quântica',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: DarkTechTheme.textPrimary,
                                ),
                              ),
                              Text(
                                'ML-KEM-768 + X25519 • Double Ratchet ativo',
                                style: TextStyle(fontSize: 12, color: DarkTechTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Número de Segurança (Safety Number)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: DarkTechTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SafetyNumberView(safetyNumber: safetyNumber),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('verify_by_qr_button'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSafetyNumberDialog();
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Verificar por QR Code'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00E599),
                      foregroundColor: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showEphemeralDialog();
                    },
                    icon: Icon(
                      _ephemeralTtlSecs > 0 ? Icons.timer : Icons.timer_outlined,
                      color: _ephemeralTtlSecs > 0 ? DarkTechTheme.secondary : DarkTechTheme.primary,
                    ),
                    label: Text(
                      _ephemeralTtlSecs > 0
                          ? 'Mensagens temporárias ativas'
                          : 'Configurar mensagens temporárias',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _scrollToEndSoon();
  }

  void _scrollToEndSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final reply = _replyingTo;
    final viewOnce = _isViewOnce;

    _textController.clear();
    setState(() {
      _replyingTo = null;
      _isViewOnce = false;
    });

    await _controller.sendText(text, replyTo: reply, isViewOnce: viewOnce);
  }

  void _startReply(MessageDto message) {
    HapticFeedback.lightImpact();
    final parsed = ParsedMessageContent.parse(message.body);
    final isOutgoing = message.direction == MessageDirectionDto.outgoing;
    final senderName = isOutgoing ? 'Você' : (_currentContactLabel ?? 'Contato');
    final isVoice = message.kind == MessageKindDto.voiceNote;
    final snippet = isVoice ? 'Nota de voz' : parsed.text;

    setState(() {
      _replyingTo = QuotedReply(
        id: message.id,
        sender: senderName,
        snippet: snippet,
        isVoice: isVoice,
      );
    });
  }

  void _showReactionPicker(MessageDto message, Offset tapPos) {
    ReactionPicker.show(
      context,
      tapPosition: tapPos,
      onSelect: (emoji) {
        _controller.sendReaction(targetMessageId: message.id, emoji: emoji);
      },
    );
  }

  // --- Controles avançados de gravação por gestos ---
  void _startRecordTimer() {
    _recordTimer?.cancel();
    _recordSeconds = 0;
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _controller.isRecording) {
        setState(() => _recordSeconds++);
      }
    });
  }

  void _stopRecordTimer() {
    _recordTimer?.cancel();
    _recordTimer = null;
    _recordSeconds = 0;
  }

  Future<void> _startRecordingGesture() async {
    _micDragAccumulatedX = 0;
    _micDragAccumulatedY = 0;
    _isMicLocked = false;
    await _controller.startRecording();
    if (_controller.isRecording) {
      _startRecordTimer();
    }
  }

  Future<void> _cancelRecordingGesture() async {
    HapticFeedback.heavyImpact();
    _stopRecordTimer();
    _isMicLocked = false;
    await _controller.cancelRecording();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gravação cancelada'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _stopAndSendRecordingGesture() async {
    _stopRecordTimer();
    _isMicLocked = false;
    await _controller.stopRecordingAndSend();
  }

  void _onMicDragUpdate(DragUpdateDetails details) {
    if (!_controller.isRecording || _isMicLocked) return;

    _micDragAccumulatedX += details.delta.dx;
    _micDragAccumulatedY += details.delta.dy;

    // Deslizar para a esquerda (<= -60px) cancela a gravação
    if (_micDragAccumulatedX <= -60) {
      _cancelRecordingGesture();
      return;
    }

    // Deslizar para cima (<= -50px) trava a gravação em modo mãos livres
    if (_micDragAccumulatedY <= -50) {
      HapticFeedback.mediumImpact();
      setState(() => _isMicLocked = true);
    }
  }

  void _onMicDragEnd([dynamic _]) {
    if (!_controller.isRecording) return;
    if (!_isMicLocked) {
      // Se não estava travada, ao soltar o dedo envia a gravação
      _stopAndSendRecordingGesture();
    }
  }

  @override
  void dispose() {
    _stopRecordTimer();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _showContactDetails,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _currentContactLabel ?? 'Conversa',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (_controller.isVerified) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.verified,
                    size: 18,
                    color: Color(0xFF00E599),
                    key: Key('verified_chat_badge'),
                  ),
                ],
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18, color: DarkTechTheme.primary),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _ephemeralTtlSecs > 0 ? Icons.timer : Icons.timer_outlined,
              color: _ephemeralTtlSecs > 0 ? DarkTechTheme.secondary : null,
            ),
            tooltip: _ephemeralTtlSecs > 0
                ? 'Mensagens temporárias ativas'
                : 'Configurar mensagens temporárias',
            onPressed: _showEphemeralDialog,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _statusLabel(),
                  style: const TextStyle(
                    fontSize: 11,
                    color: DarkTechTheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                _buildTransportPill(),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_controller.isKeyChanged)
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('key_change_banner'),
                onTap: _showSafetyNumberDialog,
                child: Container(
                  width: double.infinity,
                  color: DarkTechTheme.alert.withValues(alpha: 0.25),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: const Row(
                    children: [
                      Expanded(
                        child: Text(
                          '⚠️ Atenção: As chaves criptográficas deste contato mudaram. Toque para re-verificar o número de segurança antes de enviar mensagens.',
                          style: TextStyle(
                            color: DarkTechTheme.alert,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.chevron_right, color: DarkTechTheme.alert, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          if (_controller.connectionError != null)
            Container(
              width: double.infinity,
              color: DarkTechTheme.alert.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(12),
              child: Text(
                _controller.connectionError!,
                style: const TextStyle(color: DarkTechTheme.alert),
              ),
            ),
          if (_controller.voiceError != null)
            Container(
              width: double.infinity,
              color: DarkTechTheme.alert.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                _controller.voiceError!,
                style: const TextStyle(color: DarkTechTheme.alert),
              ),
            ),
          Expanded(
            child: _controller.messages.isEmpty
                ? const Center(
                    child: Text(
                      'Nenhuma mensagem ainda',
                      style: TextStyle(color: DarkTechTheme.textMuted),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _controller.messages.length,
                    itemBuilder: (context, index) {
                      final message = _controller.messages[index];
                      final parsed = ParsedMessageContent.parse(message.body);

                      // Oculta mensagens que são puramente comandos de reação
                      if (parsed.isReaction) {
                        return const SizedBox.shrink();
                      }

                      return SwipeToReply(
                        onReply: () => _startReply(message),
                        child: _MessageBubble(
                          message: message,
                          controller: _controller,
                          onLongPress: (tapPos) => _showReactionPicker(message, tapPos),
                        ),
                      );
                    },
                  ),
          ),

          // Pré-visualização de resposta citada
          if (_replyingTo != null)
            ReplyPreview(
              reply: _replyingTo!,
              onCancel: () => setState(() => _replyingTo = null),
            ),

          // Barra inferior de entrada ou gravador de áudio ativo
          SafeArea(
            top: false,
            child: _controller.isRecording
                ? _buildRecordingBar()
                : _buildTextInputBar(),
          ),
        ],
      ),
    );
  }

  /// Barra de entrada padrão de texto, com alternador de Visualização Única e mic
  Widget _buildTextInputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          // Alternador de Visualização Única (View-Once)
          IconButton(
            tooltip: _isViewOnce ? 'Visualização única ativa' : 'Ativar visualização única',
            icon: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isViewOnce
                    ? DarkTechTheme.secondary.withValues(alpha: 0.2)
                    : Colors.transparent,
                border: Border.all(
                  color: _isViewOnce ? DarkTechTheme.secondary : DarkTechTheme.divider,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '1',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: _isViewOnce ? DarkTechTheme.secondary : DarkTechTheme.textSecondary,
                ),
              ),
            ),
            onPressed: () {
              HapticFeedback.lightImpact();
              setState(() => _isViewOnce = !_isViewOnce);
            },
          ),
          const SizedBox(width: 4),

          // Campo de texto
          Expanded(
            child: TextField(
              controller: _textController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: _isViewOnce ? 'Mensagem de visualização única…' : 'Mensagem criptografada…',
                hintStyle: TextStyle(
                  color: _isViewOnce ? DarkTechTheme.secondary.withValues(alpha: 0.7) : DarkTechTheme.textMuted,
                ),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _handleSend(),
            ),
          ),
          const SizedBox(width: 8),

          // Botão de microfone com gestos de deslizar para cima (travar) e esquerda (cancelar)
          GestureDetector(
            onLongPressStart: (_) => _startRecordingGesture(),
            onLongPressMoveUpdate: (details) {
              _onMicDragUpdate(DragUpdateDetails(
                delta: details.offsetFromOrigin,
                globalPosition: details.globalPosition,
              ));
            },
            onLongPressEnd: _onMicDragEnd,
            child: IconButton.filled(
              tooltip: 'Segure para gravar (↑ trava, ← cancela)',
              onPressed: _controller.isSendingVoice ? null : () => _startRecordingGesture(),
              icon: const Icon(Icons.mic_rounded),
              style: IconButton.styleFrom(
                backgroundColor: DarkTechTheme.surfaceContainer,
                foregroundColor: DarkTechTheme.primary,
                side: const BorderSide(color: DarkTechTheme.divider),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Botão de enviar texto
          IconButton.filled(
            onPressed: _controller.isSending ? null : _handleSend,
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }

  /// Barra dinâmica quando a gravação de voz está ativa
  Widget _buildRecordingBar() {
    final minutes = (_recordSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_recordSeconds % 60).toString().padLeft(2, '0');

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DarkTechTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DarkTechTheme.alert.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Row(
        children: [
          // Ponto pulsante vermelho e contador
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: DarkTechTheme.alert,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$minutes:$seconds',
            style: const TextStyle(
              fontSize: 14,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              color: DarkTechTheme.alert,
            ),
          ),
          const SizedBox(width: 16),

          // Instrução de arrasto ou status travado
          Expanded(
            child: Text(
              _isMicLocked ? 'Gravação travada' : '← Cancela  •  ↑ Trava',
              style: const TextStyle(
                fontSize: 12,
                color: DarkTechTheme.textSecondary,
              ),
            ),
          ),

          // Botão de lixeira para cancelar
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: DarkTechTheme.alert),
            tooltip: 'Cancelar gravação',
            onPressed: _cancelRecordingGesture,
          ),

          // Se travada, exibe botão para finalizar e enviar
          if (_isMicLocked)
            IconButton.filled(
              icon: const Icon(Icons.send_rounded),
              tooltip: 'Enviar nota de voz',
              onPressed: _stopAndSendRecordingGesture,
            ),
        ],
      ),
    );
  }

  String _statusLabel() {
    if (_controller.connectionError != null) return 'Falha na conexão';
    return _controller.isEstablished ? 'Conectado (P2P Pós-Quântico)' : 'Conectando…';
  }

  Widget _buildTransportPill() {
    final transport = _controller.activeTransport;
    return Container(
      key: const Key('transport_indicator_pill'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: DarkTechTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: DarkTechTheme.divider,
          width: 0.8,
        ),
      ),
      child: Text(
        transport.label,
        style: const TextStyle(
          fontSize: 10.5,
          color: DarkTechTheme.textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.controller,
    required this.onLongPress,
  });

  final MessageDto message;
  final ChatController controller;
  final ValueChanged<Offset> onLongPress;

  @override
  Widget build(BuildContext context) {
    final outgoing = message.direction == MessageDirectionDto.outgoing;
    final parsed = ParsedMessageContent.parse(message.body);
    final reactions = controller.reactionsFor(message.id);
    final userReactions = controller.userReactionsFor(message.id);

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: (details) => onLongPress(details.globalPosition),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
          ),
          decoration: BoxDecoration(
            color: outgoing
                ? DarkTechTheme.surfaceContainer
                : DarkTechTheme.surface,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(outgoing ? 14 : 2),
              bottomRight: Radius.circular(outgoing ? 2 : 14),
            ),
            border: Border.all(
              color: outgoing
                  ? DarkTechTheme.primary.withValues(alpha: 0.35)
                  : DarkTechTheme.divider,
              width: 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Exibe citação de resposta se houver
              if (parsed.reply != null)
                QuotedMessageBubbleView(reply: parsed.reply!),

              // Mensagem de voz com AudioWaveformPlayer OU texto
              if (message.kind == MessageKindDto.voiceNote)
                _buildVoiceNoteContent(context)
              else if (parsed.isViewOnce)
                _buildViewOnceContent(context, parsed.text)
              else
                Text(
                  parsed.text,
                  style: const TextStyle(
                    fontSize: 14.5,
                    color: DarkTechTheme.textPrimary,
                  ),
                ),

              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (parsed.isViewOnce) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: DarkTechTheme.secondary.withValues(alpha: 0.15),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.looks_one_rounded, size: 11, color: DarkTechTheme.secondary),
                          SizedBox(width: 2),
                          Text(
                            'Única',
                            style: TextStyle(
                              fontSize: 10,
                              color: DarkTechTheme.secondary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                  ] else if (message.isEphemeral) ...[
                    const Icon(Icons.timer_outlined, size: 12, color: DarkTechTheme.secondary),
                    const SizedBox(width: 4),
                  ],
                  if (outgoing)
                    Text(
                      _deliveryLabel(message.deliveryState),
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: DarkTechTheme.textMuted,
                      ),
                    ),
                ],
              ),

              // Reações ativas no rodapé do balão
              if (reactions.isNotEmpty)
                MessageReactionsView(
                  reactions: reactions,
                  userReactions: userReactions,
                  onReactionTap: (emoji) {
                    controller.sendReaction(targetMessageId: message.id, emoji: emoji);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceNoteContent(BuildContext context) {
    final ready = controller.isVoiceNoteReady(message);
    if (!ready) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: DarkTechTheme.scaffoldBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: DarkTechTheme.primary,
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Recebendo nota de voz…',
              style: TextStyle(fontSize: 12.5, color: DarkTechTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    final audioBytes = controller.getVoiceNoteAudio(message);
    return AudioWaveformPlayer(
      audioBytes: audioBytes,
    );
  }

  Widget _buildViewOnceContent(BuildContext context, String text) {
    final isOutgoing = message.direction == MessageDirectionDto.outgoing;
    final isOpened = controller.isViewOnceOpened(message.id);

    if (isOutgoing) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: DarkTechTheme.secondary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.looks_one_rounded, size: 16, color: DarkTechTheme.secondary),
            SizedBox(width: 6),
            Text(
              'Mensagem de visualização única enviada',
              style: TextStyle(fontSize: 12.5, color: DarkTechTheme.secondary),
            ),
          ],
        ),
      );
    }

    if (isOpened) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: DarkTechTheme.scaffoldBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off_outlined, size: 16, color: DarkTechTheme.textMuted),
            SizedBox(width: 6),
            Text(
              'Mensagem visualizada (autodestruída)',
              style: TextStyle(
                fontSize: 12.5,
                color: DarkTechTheme.textMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openViewOnceDialog(context, text),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: DarkTechTheme.secondary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DarkTechTheme.secondary, width: 1.0),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.looks_one_rounded, size: 18, color: DarkTechTheme.secondary),
              SizedBox(width: 8),
              Text(
                'Toque para visualizar mensagem única',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: DarkTechTheme.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openViewOnceDialog(BuildContext context, String text) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.visibility_outlined, color: DarkTechTheme.secondary),
            SizedBox(width: 8),
            Text('Visualização Única'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: const TextStyle(fontSize: 16, color: DarkTechTheme.textPrimary),
            ),
            const SizedBox(height: 16),
            const Text(
              'Aviso: esta mensagem será apagada imediatamente da tela após fechar.',
              style: TextStyle(fontSize: 11, color: DarkTechTheme.secondary),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              controller.markViewOnceOpened(message.id);
            },
            child: const Text('Entendido (Fechar e Apagar)'),
          ),
        ],
      ),
    );
  }

  String _deliveryLabel(DeliveryStateDto state) {
    switch (state) {
      case DeliveryStateDto.pending:
        return 'Enviando…';
      case DeliveryStateDto.sent:
        return 'Enviada';
      case DeliveryStateDto.delivered:
        return 'Entregue';
      case DeliveryStateDto.failed:
        return 'Falhou';
    }
  }
}
