import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Máscara visual do scanner com visor central e cantoneiras verde-menta.
class ScannerViewfinder extends StatelessWidget {
  const ScannerViewfinder({
    super.key,
    this.boxSize = 250.0,
    this.instruction = 'Aponte a câmera para o QR Code do contato',
  });

  final double boxSize;
  final String instruction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = constraints.maxHeight;

        return Stack(
          children: [
            // Fundo escuro com orifício recortado
            ColorFiltered(
              colorFilter: const ColorFilter.mode(
                ViskaColors.bgScrim,
                BlendMode.srcOut,
              ),
              child: Stack(
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.transparent,
                      backgroundBlendMode: BlendMode.dstOut,
                    ),
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: Container(
                      width: boxSize,
                      height: boxSize,
                      decoration: const BoxDecoration(
                        color: Colors.red, // Qualquer cor serve para o recorte do blendMode
                        borderRadius: ViskaRadii.borderLg,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Cantoneiras estéticas do visor
            Center(
              child: SizedBox(
                width: boxSize,
                height: boxSize,
                child: CustomPaint(
                  painter: _CornerBracketPainter(
                    color: ViskaColors.trustDefault,
                    cornerLength: 28.0,
                    strokeWidth: 3.5,
                  ),
                ),
              ),
            ),
            // Instrução textual abaixo do visor
            Positioned(
              top: (screenHeight / 2) + (boxSize / 2) + ViskaSpacing.space2xl,
              left: ViskaSpacing.spaceXl,
              right: ViskaSpacing.spaceXl,
              child: Text(
                instruction,
                textAlign: TextAlign.center,
                style: ViskaTypography.bodyMedium.copyWith(
                  color: ViskaColors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CornerBracketPainter extends CustomPainter {
  const _CornerBracketPainter({
    required this.color,
    required this.cornerLength,
    required this.strokeWidth,
  });

  final Color color;
  final double cornerLength;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;

    // Canto Superior Esquerdo
    canvas.drawLine(Offset(0, cornerLength), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), Offset(cornerLength, 0), paint);

    // Canto Superior Direito
    canvas.drawLine(Offset(w - cornerLength, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, cornerLength), paint);

    // Canto Inferior Esquerdo
    canvas.drawLine(Offset(0, h - cornerLength), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(cornerLength, h), paint);

    // Canto Inferior Direito
    canvas.drawLine(Offset(w - cornerLength, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - cornerLength), paint);
  }

  @override
  bool shouldRepaint(covariant _CornerBracketPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.cornerLength != cornerLength ||
      oldDelegate.strokeWidth != strokeWidth;
}
