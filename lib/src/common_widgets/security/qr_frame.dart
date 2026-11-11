import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';

/// Moldura estética dark-tech com cantos destacados para exibição de QR Code.
class QrFrame extends StatelessWidget {
  const QrFrame({
    super.key,
    required this.child,
    this.size = 240.0,
  });

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
      decoration: BoxDecoration(
        color: Colors.white, // Fundo branco de alto contraste obrigatório para leitura óptica confiável
        borderRadius: ViskaRadii.borderLg,
        border: Border.all(
          color: ViskaColors.trustDefault,
          width: 2.0,
        ),
        boxShadow: [
          BoxShadow(
            color: ViskaColors.trustDefault.withAlpha(38),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}
