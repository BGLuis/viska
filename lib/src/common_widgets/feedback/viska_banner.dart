import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

enum ViskaBannerTone {
  danger,
  warning,
  info,
  trust,
}

/// Banner de alerta ou notificação de segurança com botão de ação inline.
class ViskaBanner extends StatelessWidget {
  const ViskaBanner({
    super.key,
    required this.message,
    this.title,
    this.tone = ViskaBannerTone.warning,
    this.actionLabel,
    this.onActionPressed,
    this.icon,
  });

  final String message;
  final String? title;
  final ViskaBannerTone tone;
  final String? actionLabel;
  final VoidCallback? onActionPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    Color border;
    IconData defaultIcon;

    switch (tone) {
      case ViskaBannerTone.danger:
        bg = ViskaColors.dangerContainer;
        fg = ViskaColors.dangerOnContainer;
        border = ViskaColors.dangerDefault.withAlpha(89);
        defaultIcon = Icons.error_outline_rounded;
        break;
      case ViskaBannerTone.warning:
        bg = ViskaColors.ephemeralContainer;
        fg = ViskaColors.ephemeralOnContainer;
        border = ViskaColors.ephemeralDefault.withAlpha(89);
        defaultIcon = Icons.warning_amber_rounded;
        break;
      case ViskaBannerTone.info:
        bg = ViskaColors.bgSurfaceRaised;
        fg = ViskaColors.textPrimary;
        border = ViskaColors.borderStrong;
        defaultIcon = Icons.info_outline_rounded;
        break;
      case ViskaBannerTone.trust:
        bg = ViskaColors.trustContainer;
        fg = ViskaColors.trustOnContainer;
        border = ViskaColors.trustBorder;
        defaultIcon = Icons.info_outline_rounded;
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: ViskaRadii.borderMd,
        border: Border.all(color: border, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon ?? defaultIcon, size: 20, color: fg),
              const SizedBox(width: ViskaSpacing.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: ViskaTypography.labelLarge.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: ViskaSpacing.space2xs),
                    ],
                    Text(
                      message,
                      style: ViskaTypography.bodySmall.copyWith(
                        color: fg.withAlpha(230),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (actionLabel != null && onActionPressed != null) ...[
            const SizedBox(height: ViskaSpacing.spaceSm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onActionPressed,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ViskaSpacing.spaceMd,
                    vertical: ViskaSpacing.spaceXs,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  actionLabel!.toUpperCase(),
                  style: ViskaTypography.labelLarge.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
