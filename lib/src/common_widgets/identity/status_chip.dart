import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

enum StatusChipTone {
  trust,
  ephemeral,
  danger,
  neutral,
}

/// Chip de status de segurança, efemeridade ou verificação.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.icon,
    this.tone = StatusChipTone.neutral,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final StatusChipTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    Color border;

    switch (tone) {
      case StatusChipTone.trust:
        bg = ViskaColors.trustContainer;
        fg = ViskaColors.trustOnContainer;
        border = ViskaColors.trustBorder;
        break;
      case StatusChipTone.ephemeral:
        bg = ViskaColors.ephemeralContainer;
        fg = ViskaColors.ephemeralOnContainer;
        border = ViskaColors.ephemeralSubtle;
        break;
      case StatusChipTone.danger:
        bg = ViskaColors.dangerContainer;
        fg = ViskaColors.dangerOnContainer;
        border = ViskaColors.dangerSubtle;
        break;
      case StatusChipTone.neutral:
        bg = ViskaColors.bgSurfaceRaised;
        fg = ViskaColors.textSecondary;
        border = ViskaColors.borderDefault;
        break;
    }

    final content = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ViskaSpacing.spaceSm,
        vertical: ViskaSpacing.space2xs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: ViskaRadii.borderFull,
        border: Border.all(color: border, width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: ViskaSpacing.spaceXs),
          ],
          Text(
            label,
            style: ViskaTypography.bodySmall.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: ViskaRadii.borderFull,
        child: content,
      );
    }
    return content;
  }
}
