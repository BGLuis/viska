import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Emojis populares para reações rápidas.
const List<String> kPopularReactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Menu flutuante acionado por toque longo em mensagens para seleção rápida de reações.
class ReactionPicker extends StatelessWidget {
  const ReactionPicker({
    super.key,
    required this.onSelect,
    this.selectedEmoji,
    this.emojis = kPopularReactionEmojis,
  });

  final ValueChanged<String> onSelect;
  final String? selectedEmoji;
  final List<String> emojis;

  /// Exibe o menu flutuante posicionado na tela.
  static Future<String?> show(
    BuildContext context, {
    required Offset tapPosition,
    String? selectedEmoji,
    List<String> emojis = kPopularReactionEmojis,
    ValueChanged<String>? onSelect,
  }) async {
    HapticFeedback.mediumImpact();

    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (ctx) {
        final mediaQuery = MediaQuery.of(ctx);
        final screenWidth = mediaQuery.size.width;
        final screenHeight = mediaQuery.size.height;

        // Garante que o menu flutuante fique visível dentro da tela
        final double top = (tapPosition.dy - 60).clamp(48.0, screenHeight - 90);
        final double left = (tapPosition.dx - 140).clamp(16.0, screenWidth - 280);

        return Stack(
          children: [
            Positioned(
              top: top,
              left: left,
              child: Material(
                color: Colors.transparent,
                child: ReactionPicker(
                  selectedEmoji: selectedEmoji,
                  emojis: emojis,
                  onSelect: (emoji) {
                    Navigator.of(ctx).pop(emoji);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    if (result != null && onSelect != null) {
      onSelect(result);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: DarkTechTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: DarkTechTheme.divider, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: emojis.map((emoji) {
          final isSelected = emoji == selectedEmoji;
          return _EmojiButton(
            emoji: emoji,
            isSelected: isSelected,
            onTap: () {
              HapticFeedback.lightImpact();
              onSelect(emoji);
            },
          );
        }).toList(),
      ),
    );
  }
}

class _EmojiButton extends StatefulWidget {
  const _EmojiButton({
    required this.emoji,
    required this.isSelected,
    required this.onTap,
  });

  final String emoji;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? 1.35 : (widget.isSelected ? 1.15 : 1.0),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutBack,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.isSelected
                ? DarkTechTheme.primary.withValues(alpha: 0.25)
                : Colors.transparent,
          ),
          child: Text(
            widget.emoji,
            style: const TextStyle(fontSize: 22),
          ),
        ),
      ),
    );
  }
}

/// Renderização das reações ativas na parte inferior do balão de mensagem.
class MessageReactionsView extends StatelessWidget {
  const MessageReactionsView({
    super.key,
    required this.reactions,
    this.userReactions = const {},
    this.onReactionTap,
  });

  /// Mapeamento de emoji para quantidade de vezes que foi adicionado.
  final Map<String, int> reactions;

  /// Conjunto de emojis que o usuário local marcou nesta mensagem.
  final Set<String> userReactions;

  /// Callback acionado ao tocar em uma pílula de reação existente.
  final ValueChanged<String>? onReactionTap;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: reactions.entries.map((entry) {
          final emoji = entry.key;
          final count = entry.value;
          final isFromUser = userReactions.contains(emoji);

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onReactionTap != null ? () => onReactionTap!(emoji) : null,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isFromUser
                      ? DarkTechTheme.primary.withValues(alpha: 0.2)
                      : DarkTechTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isFromUser ? DarkTechTheme.primary : DarkTechTheme.divider,
                    width: 1.0,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      emoji,
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (count > 1) ...[
                      const SizedBox(width: 3),
                      Text(
                        count.toString(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isFromUser ? DarkTechTheme.primary : DarkTechTheme.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
