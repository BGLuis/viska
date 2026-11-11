import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';

enum ViskaIconButtonVariant {
  standard,
  muted,
  tonal,
  trust,
  danger,
}

/// Botão de ícone dark-tech com variantes visuais do Figma.
class ViskaIconButton extends StatelessWidget {
  const ViskaIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.variant = ViskaIconButtonVariant.standard,
    this.tooltip,
    this.size = 40.0,
    this.iconSize = 20.0,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final ViskaIconButtonVariant variant;
  final String? tooltip;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;

    Color bg;
    Color fg;
    BorderSide borderSide = BorderSide.none;

    switch (variant) {
      case ViskaIconButtonVariant.standard:
        bg = Colors.transparent;
        fg = isEnabled ? ViskaColors.textPrimary : ViskaColors.textMuted;
        break;
      case ViskaIconButtonVariant.muted:
        bg = Colors.transparent;
        fg = isEnabled ? ViskaColors.textSecondary : ViskaColors.textMuted;
        break;
      case ViskaIconButtonVariant.tonal:
        bg = isEnabled ? ViskaColors.bgSurfaceRaised : ViskaColors.bgCanvas;
        fg = isEnabled ? ViskaColors.textPrimary : ViskaColors.textMuted;
        borderSide = const BorderSide(color: ViskaColors.borderDefault);
        break;
      case ViskaIconButtonVariant.trust:
        bg = isEnabled ? ViskaColors.trustContainer : ViskaColors.bgCanvas;
        fg = isEnabled ? ViskaColors.trustDefault : ViskaColors.textMuted;
        borderSide = const BorderSide(color: ViskaColors.trustBorder);
        break;
      case ViskaIconButtonVariant.danger:
        bg = isEnabled ? ViskaColors.dangerContainer : ViskaColors.bgCanvas;
        fg = isEnabled ? ViskaColors.dangerDefault : ViskaColors.textMuted;
        borderSide = BorderSide(color: ViskaColors.dangerDefault.withAlpha(89));
        break;
    }

    Widget button = Material(
      color: bg,
      borderRadius: ViskaRadii.borderMd,
      child: InkWell(
        onTap: onPressed,
        borderRadius: ViskaRadii.borderMd,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: ViskaRadii.borderMd,
            border: borderSide != BorderSide.none ? Border.fromBorderSide(borderSide) : null,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}
