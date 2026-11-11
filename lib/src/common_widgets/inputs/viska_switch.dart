import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';

/// Alternador booleano (Switch) customizado no estilo dark-tech.
class ViskaSwitch extends StatelessWidget {
  const ViskaSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: ViskaColors.trustDefault,
      activeTrackColor: ViskaColors.trustContainer,
      inactiveThumbColor: ViskaColors.textSecondary,
      inactiveTrackColor: ViskaColors.bgSurfaceRaised,
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return ViskaColors.trustBorder;
        }
        return ViskaColors.borderStrong;
      }),
    );
  }
}
