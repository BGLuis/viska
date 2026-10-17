import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_radii.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';

/// Tela dedicada para rejeição de pareamento / mismatch de chave criptográfica (Tela 17 / Issue #13).
class PairingRejectedScreen extends StatelessWidget {
  const PairingRejectedScreen({
    super.key,
    this.contactName,
    this.reason = 'A chave pública apresentada não corresponde à identidade criptográfica registrada anteriormente para este contato.',
    this.onDismiss,
  });

  final String? contactName;
  final String reason;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(
        title: const Text('Alerta de Segurança'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            if (onDismiss != null) {
              onDismiss!();
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(ViskaSpacing.space2xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: ViskaColors.dangerContainer,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ViskaColors.dangerDefault,
                      width: 2.0,
                    ),
                  ),
                  child: const Icon(
                    Icons.gpp_bad_rounded,
                    size: 44,
                    color: ViskaColors.dangerDefault,
                  ),
                ),
              ),
              const SizedBox(height: ViskaSpacing.space2xl),
              Text(
                'Pareamento Rejeitado',
                textAlign: TextAlign.center,
                style: ViskaTypography.headline.copyWith(
                  color: ViskaColors.dangerDefault,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                contactName != null
                    ? 'Inconsistência criptográfica detectada com $contactName'
                    : 'Inconsistência de chave criptográfica detectada',
                textAlign: TextAlign.center,
                style: ViskaTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              Container(
                padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
                decoration: BoxDecoration(
                  color: ViskaColors.bgSurface,
                  borderRadius: ViskaRadii.borderLg,
                  border: Border.all(
                    color: ViskaColors.dangerDefault.withAlpha(89),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 20,
                          color: ViskaColors.dangerDefault,
                        ),
                        const SizedBox(width: ViskaSpacing.spaceSm),
                        Text(
                          'POSSÍVEL ATAQUE MITM',
                          style: ViskaTypography.labelOverline.copyWith(
                            color: ViskaColors.dangerDefault,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ViskaSpacing.spaceSm),
                    Text(
                      reason,
                      style: ViskaTypography.bodyMedium.copyWith(
                        color: ViskaColors.textPrimary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: ViskaSpacing.spaceMd),
                    Text(
                      'Para sua proteção, o Viska recusa conexões com chaves divergentes. Recomenda-se realizar uma verificação presencial por QR Code.',
                      style: ViskaTypography.bodySmall.copyWith(
                        color: ViskaColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              ViskaButton(
                label: 'VOLTAR COM SEGURANÇA',
                style: ViskaButtonStyle.primary,
                isFullWidth: true,
                onPressed: () {
                  if (onDismiss != null) {
                    onDismiss!();
                  } else {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
