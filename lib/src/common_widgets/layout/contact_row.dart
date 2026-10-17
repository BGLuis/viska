import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import '../identity/viska_avatar.dart';

/// Linha de contato estilizada para a tela inicial / lista de conversas.
class ContactRow extends StatelessWidget {
  const ContactRow({
    super.key,
    required this.name,
    this.isVerified = false,
    this.lastMessage,
    this.timestamp,
    this.unreadCount = 0,
    this.onTap,
    this.onLongPress,
  });

  final String name;
  final bool isVerified;
  final String? lastMessage;
  final String? timestamp;
  final int unreadCount;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    // Linha 2 de contingência do Figma caso não haja query de última mensagem agregada:
    final subtitleText = lastMessage ??
        (isVerified ? 'Identidade criptográfica verificada' : 'Não verificado');
    final subtitleColor = isVerified && lastMessage == null
        ? ViskaColors.trustOnContainer
        : ViskaColors.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ViskaSpacing.spaceLg,
            vertical: ViskaSpacing.spaceMd,
          ),
          child: Row(
            children: [
              ViskaAvatar(
                name: name,
                size: ViskaAvatarSize.lg,
                isVerified: isVerified,
              ),
              const SizedBox(width: ViskaSpacing.spaceLg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: ViskaTypography.titleMedium.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (timestamp != null) ...[
                          const SizedBox(width: ViskaSpacing.spaceSm),
                          Text(
                            timestamp!,
                            style: ViskaTypography.bodySmall.copyWith(
                              color: unreadCount > 0
                                  ? ViskaColors.trustDefault
                                  : ViskaColors.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: ViskaSpacing.spaceXs),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            subtitleText,
                            style: ViskaTypography.bodySmall.copyWith(
                              color: subtitleColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (unreadCount > 0) ...[
                          const SizedBox(width: ViskaSpacing.spaceSm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6.0,
                              vertical: 2.0,
                            ),
                            decoration: const BoxDecoration(
                              color: ViskaColors.trustDefault,
                              borderRadius: ViskaRadii.borderFull,
                            ),
                            constraints: const BoxConstraints(minWidth: 18),
                            alignment: Alignment.center,
                            child: Text(
                              unreadCount > 99 ? '99+' : unreadCount.toString(),
                              style: ViskaTypography.monoSmall.copyWith(
                                color: ViskaColors.trustOn,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
