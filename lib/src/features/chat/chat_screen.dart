import 'package:flutter/material.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

import '../../transport/p2p_transport.dart';
import '../../transport/p2p_transport_router.dart';
import 'chat_controller.dart';

/// Tela de chat com um contato — Fase 3, F6.
///
/// `StatefulWidget` puro, mesmo padrão do resto do projeto (sem lib de
/// state management): a lógica mora em [ChatController], esta classe só
/// escuta e desenha.
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

  /// Apelido ou identificador curto para o título da tela — puramente
  /// cosmético, esta fase não tem gestão de apelido nenhuma.
  final String? contactLabel;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _controller;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

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
    _textController.clear();
    await _controller.sendText(text);
  }

  @override
  void dispose() {
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
        title: Text(widget.contactLabel ?? 'Conversa'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _statusLabel(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_controller.connectionError != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                _controller.connectionError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          Expanded(
            child: _controller.messages.isEmpty
                ? const Center(child: Text('Nenhuma mensagem ainda'))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _controller.messages.length,
                    itemBuilder: (context, index) =>
                        _MessageBubble(message: _controller.messages[index]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        hintText: 'Mensagem',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _handleSend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _controller.isSending ? null : _handleSend,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel() {
    if (_controller.connectionError != null) return 'Falha na conexão';
    return _controller.isEstablished ? 'Conectado' : 'Conectando…';
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final MessageDto message;

  @override
  Widget build(BuildContext context) {
    final outgoing = message.direction == MessageDirectionDto.outgoing;
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: outgoing ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message.body),
            if (outgoing) ...[
              const SizedBox(height: 2),
              Text(
                _deliveryLabel(message.deliveryState),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
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
