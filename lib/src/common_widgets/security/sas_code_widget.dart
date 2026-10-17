import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Exibição estilizada dos 6 dígitos de autenticação SAS (Short Authentication String).
///
/// Apresenta o código em duas trincas em caixas monoespaçadas de alta legibilidade.
class SasCodeWidget extends StatelessWidget {
  const SasCodeWidget({
    super.key,
    required this.sasCode,
  });

  /// Código SAS de 6 dígitos (ex: "492183" ou "492 183").
  final String sasCode;

  @override
  Widget build(BuildContext context) {
    final cleanDigits = sasCode.replaceAll(RegExp(r'\s+'), '');
    final part1 = cleanDigits.length >= 3 ? cleanDigits.substring(0, 3) : cleanDigits;
    final part2 = cleanDigits.length > 3 ? cleanDigits.substring(3) : '';

    Widget buildBlock(String digits) {
      return Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ViskaSpacing.spaceLg,
          vertical: ViskaSpacing.spaceMd,
        ),
        decoration: BoxDecoration(
          color: ViskaColors.bgSurfaceRaised,
          borderRadius: ViskaRadii.borderMd,
          border: Border.all(
            color: ViskaColors.trustBorder,
            width: 1.5,
          ),
        ),
        child: Text(
          digits,
          style: ViskaTypography.monoLarge.copyWith(
            fontSize: 28,
            letterSpacing: 4.0,
            fontWeight: FontWeight.w600,
            color: ViskaColors.trustDefault,
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        buildBlock(part1),
        const SizedBox(width: ViskaSpacing.spaceLg),
        buildBlock(part2),
      ],
    );
  }
}
