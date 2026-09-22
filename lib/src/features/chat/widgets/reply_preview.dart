import 'package:flutter/material.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Modelo de dados imutável representando uma mensagem citada em resposta.
class QuotedReply {
  const QuotedReply({
    required this.id,
    required this.sender,
    required this.snippet,
    this.isVoice = false,
  });

  final int id;
  final String sender;
  final String snippet;
  final bool isVoice;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender': sender,
        'snippet': snippet,
        'isVoice': isVoice,
      };

  factory QuotedReply.fromJson(Map<String, dynamic> json) {
    return QuotedReply(
      id: json['id'] as int? ?? 0,
      sender: json['sender'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      isVoice: json['isVoice'] as bool? ?? false,
    );
  }
}

/// Widget exibido logo acima do campo de entrada de texto quando o usuário
/// está respondendo a uma mensagem específica.
class ReplyPreview extends StatelessWidget {
  const ReplyPreview({
    super.key,
    required this.reply,
    required this.onCancel,
  });

  final QuotedReply reply;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DarkTechTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DarkTechTheme.divider, width: 1.0),
      ),
      child: Row(
        children: [
          // Linha de acento vertical
          Container(
            width: 3.5,
            height: 36,
            decoration: BoxDecoration(
              color: DarkTechTheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),

          // Informações da citação
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.reply_rounded,
                      size: 14,
                      color: DarkTechTheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Respondendo a ${reply.sender}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: DarkTechTheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (reply.isVoice) ...[
                      const Icon(Icons.mic_rounded, size: 13, color: DarkTechTheme.textSecondary),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        reply.snippet.isEmpty ? (reply.isVoice ? 'Nota de voz' : 'Mensagem') : reply.snippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: DarkTechTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Botão fechar / cancelar resposta
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            color: DarkTechTheme.textMuted,
            splashRadius: 18,
            tooltip: 'Cancelar resposta',
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// Exibição da mensagem citada dentro do próprio balão de mensagem.
class QuotedMessageBubbleView extends StatelessWidget {
  const QuotedMessageBubbleView({
    super.key,
    required this.reply,
    this.onTap,
  });

  final QuotedReply reply;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: DarkTechTheme.scaffoldBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: DarkTechTheme.primary,
              width: 3.0,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              reply.sender,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: DarkTechTheme.primary,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (reply.isVoice) ...[
                  const Icon(Icons.mic, size: 12, color: DarkTechTheme.textSecondary),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    reply.snippet.isEmpty ? (reply.isVoice ? 'Nota de voz' : 'Mensagem') : reply.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: DarkTechTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
