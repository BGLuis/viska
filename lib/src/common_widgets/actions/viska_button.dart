import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

enum ViskaButtonStyle {
  primary,
  secondary,
  ghost,
  danger,
}

/// Botão de ação padrão do Viska conforme o Design System Figma.
class ViskaButton extends StatelessWidget {
  const ViskaButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.style = ViskaButtonStyle.primary,
    this.isLoading = false,
    this.isFullWidth = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final ViskaButtonStyle style;
  final bool isLoading;
  final bool isFullWidth;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null && !isLoading;

    Color bg;
    Color fg;
    BorderSide borderSide = BorderSide.none;

    switch (style) {
      case ViskaButtonStyle.primary:
        bg = isEnabled ? ViskaColors.trustDefault : ViskaColors.bgSurfaceRaised;
        fg = isEnabled ? ViskaColors.trustOn : ViskaColors.textMuted;
        break;
      case ViskaButtonStyle.secondary:
        bg = isEnabled ? ViskaColors.bgSurfaceRaised : ViskaColors.bgCanvas;
        fg = isEnabled ? ViskaColors.textPrimary : ViskaColors.textMuted;
        borderSide = BorderSide(
          color: isEnabled ? ViskaColors.borderStrong : ViskaColors.borderDefault,
        );
        break;
      case ViskaButtonStyle.ghost:
        bg = Colors.transparent;
        fg = isEnabled ? ViskaColors.trustDefault : ViskaColors.textMuted;
        break;
      case ViskaButtonStyle.danger:
        bg = isEnabled ? ViskaColors.dangerContainer : ViskaColors.bgCanvas;
        fg = isEnabled ? ViskaColors.dangerOnContainer : ViskaColors.textMuted;
        borderSide = BorderSide(
          color: isEnabled ? ViskaColors.dangerDefault.withAlpha(89) : ViskaColors.borderDefault,
        );
        break;
    }

    Widget content = Row(
      mainAxisSize: isFullWidth ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLoading) ...[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(fg),
            ),
          ),
          const SizedBox(width: ViskaSpacing.spaceSm),
        ] else if (icon != null) ...[
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: ViskaSpacing.spaceSm),
        ],
        Text(
          label,
          style: ViskaTypography.labelLarge.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    final buttonWidget = Material(
      color: bg,
      borderRadius: ViskaRadii.borderMd,
      child: InkWell(
        onTap: isEnabled ? onPressed : null,
        borderRadius: ViskaRadii.borderMd,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: ViskaRadii.borderMd,
            border: borderSide != BorderSide.none ? Border.fromBorderSide(borderSide) : null,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: ViskaSpacing.spaceLg,
            vertical: ViskaSpacing.spaceMd,
          ),
          alignment: Alignment.center,
          child: content,
        ),
      ),
    );

    if (isFullWidth) {
      return SizedBox(
        width: double.infinity,
        child: buttonWidget,
      );
    }
    return buttonWidget;
  }
}
