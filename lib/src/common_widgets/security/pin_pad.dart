import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Teclado numérico in-app para entrada segura de PIN sem invocar o teclado do sistema operacional.
///
/// Previne interceptações por IMEs de terceiros, keyloggers e telemetria de digitação.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.onDigitPressed,
    required this.onBackspacePressed,
    this.leftAction,
    this.keySize = 72.0,
  });

  final ValueChanged<String> onDigitPressed;
  final VoidCallback onBackspacePressed;
  final Widget? leftAction;
  final double keySize;

  Widget _buildKey(BuildContext context, String text, VoidCallback onTap) {
    return SizedBox(
      width: keySize,
      height: keySize,
      child: Material(
        color: ViskaColors.bgSurfaceRaised,
        shape: const CircleBorder(
          side: BorderSide(color: ViskaColors.borderDefault, width: 1.0),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          child: Center(
            child: Text(
              text,
              style: ViskaTypography.titleLarge.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                color: ViskaColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackspaceKey(BuildContext context) {
    return SizedBox(
      width: keySize,
      height: keySize,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.lightImpact();
            onBackspacePressed();
          },
          child: const Center(
            child: Icon(
              Icons.backspace_outlined,
              size: 24,
              color: ViskaColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKey(context, '1', () => onDigitPressed('1')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '2', () => onDigitPressed('2')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '3', () => onDigitPressed('3')),
          ],
        ),
        const SizedBox(height: ViskaSpacing.spaceLg),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKey(context, '4', () => onDigitPressed('4')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '5', () => onDigitPressed('5')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '6', () => onDigitPressed('6')),
          ],
        ),
        const SizedBox(height: ViskaSpacing.spaceLg),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKey(context, '7', () => onDigitPressed('7')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '8', () => onDigitPressed('8')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '9', () => onDigitPressed('9')),
          ],
        ),
        const SizedBox(height: ViskaSpacing.spaceLg),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: keySize,
              height: keySize,
              child: leftAction != null ? Center(child: leftAction!) : null,
            ),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildKey(context, '0', () => onDigitPressed('0')),
            const SizedBox(width: ViskaSpacing.space2xl),
            _buildBackspaceKey(context),
          ],
        ),
      ],
    );
  }
}
