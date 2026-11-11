import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_spacing.dart';

/// Indicador visual de pontos preenchidos para entrada de PIN seguro.
class PinDots extends StatelessWidget {
  const PinDots({
    super.key,
    required this.length,
    required this.filledCount,
    this.hasError = false,
    this.dotSize = 14.0,
  });

  final int length;
  final int filledCount;
  final bool hasError;
  final double dotSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: List.generate(length, (index) {
        final isFilled = index < filledCount;

        Color dotColor;
        Color borderColor;

        if (hasError) {
          dotColor = ViskaColors.dangerDefault;
          borderColor = ViskaColors.dangerDefault;
        } else if (isFilled) {
          dotColor = ViskaColors.trustDefault;
          borderColor = ViskaColors.trustDefault;
        } else {
          dotColor = Colors.transparent;
          borderColor = ViskaColors.borderStrong;
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: ViskaSpacing.spaceSm),
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
            border: Border.all(
              color: borderColor,
              width: 1.5,
            ),
          ),
        );
      }),
    );
  }
}
