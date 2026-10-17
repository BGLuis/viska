import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import '../inputs/viska_switch.dart';

enum SettingsRowType {
  navigation,
  toggle,
  value,
  destructive,
}

/// Linha de item de configuração com 4 variantes semânticas do Figma.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.type = SettingsRowType.navigation,
    this.valueText,
    this.toggleValue = false,
    this.onToggleChanged,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final SettingsRowType type;
  final String? valueText;
  final bool toggleValue;
  final ValueChanged<bool>? onToggleChanged;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDestructive = type == SettingsRowType.destructive;
    final primaryColor = isDestructive ? ViskaColors.dangerDefault : ViskaColors.textPrimary;
    final iconColor = isDestructive ? ViskaColors.dangerDefault : ViskaColors.textSecondary;

    final Widget trailingWidget;
    switch (type) {
      case SettingsRowType.navigation:
        trailingWidget = const Icon(
          Icons.chevron_right_rounded,
          color: ViskaColors.textMuted,
          size: 20,
        );
        break;
      case SettingsRowType.toggle:
        trailingWidget = ViskaSwitch(
          value: toggleValue,
          onChanged: onToggleChanged,
        );
        break;
      case SettingsRowType.value:
        trailingWidget = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (valueText != null)
              Text(
                valueText!,
                style: ViskaTypography.bodySmall.copyWith(
                  color: ViskaColors.textSecondary,
                ),
              ),
            const SizedBox(width: ViskaSpacing.spaceXs),
            const Icon(
              Icons.chevron_right_rounded,
              color: ViskaColors.textMuted,
              size: 18,
            ),
          ],
        );
        break;
      case SettingsRowType.destructive:
        trailingWidget = const Icon(
          Icons.chevron_right_rounded,
          color: ViskaColors.dangerDefault,
          size: 20,
        );
        break;
    }

    return InkWell(
      onTap: type == SettingsRowType.toggle
          ? () => onToggleChanged?.call(!toggleValue)
          : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ViskaSpacing.spaceLg,
          vertical: ViskaSpacing.spaceMd,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 22, color: iconColor),
              const SizedBox(width: ViskaSpacing.spaceLg),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: ViskaTypography.bodyLarge.copyWith(
                      color: primaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: ViskaSpacing.space2xs),
                    Text(
                      subtitle!,
                      style: ViskaTypography.bodySmall.copyWith(
                        color: ViskaColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: ViskaSpacing.spaceMd),
            trailingWidget,
          ],
        ),
      ),
    );
  }
}
