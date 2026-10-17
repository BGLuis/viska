import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/security/sas_code_widget.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_radii.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';

/// Tela dedicada para validação visual dos 6 dígitos SAS (Tela 16 do Figma).
class SasConfirmationScreen extends StatelessWidget {
  const SasConfirmationScreen({
    super.key,
    required this.peerName,
    required this.sasCode,
    required this.onConfirm,
    required this.onReject,
    this.isInitiator = false,
  });

  final String peerName;
  final String sasCode;
  final VoidCallback onConfirm;
  final VoidCallback onReject;
  final bool isInitiator;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(
        title: const Text('Confirmação de Pareamento'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: onReject,
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
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: ViskaColors.trustContainer,
                    shape: BoxShape.circle,
                    border: Border.all(color: ViskaColors.trustBorder, width: 1.5),
                  ),
                  child: const Icon(
                    Icons.security_rounded,
                    size: 32,
                    color: ViskaColors.trustDefault,
                  ),
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceXl),
              Text(
                'Validar Código SAS',
                textAlign: TextAlign.center,
                style: ViskaTypography.headline,
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                'Confirme verbalmente ou visualmente se os 6 dígitos abaixo são exatamente iguais aos exibidos no aparelho de $peerName.',
                textAlign: TextAlign.center,
                style: ViskaTypography.bodyMedium.copyWith(
                  color: ViskaColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: ViskaSpacing.space2xl),
              Center(
                child: SasCodeWidget(sasCode: sasCode),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              Container(
                padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
                decoration: BoxDecoration(
                  color: ViskaColors.bgSurfaceRaised,
                  borderRadius: ViskaRadii.borderMd,
                  border: Border.all(color: ViskaColors.borderDefault),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 20,
                      color: ViskaColors.textMuted,
                    ),
                    const SizedBox(width: ViskaSpacing.spaceSm),
                    Expanded(
                      child: Text(
                        'Se os dígitos divergirem, cancele imediatamente. Isso pode indicar uma tentativa de interceptação ativa.',
                        style: ViskaTypography.bodySmall.copyWith(
                          color: ViskaColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              ViskaButton(
                label: 'CÓDIGO É IDÊNTICO (CONFIRMAR)',
                style: ViskaButtonStyle.primary,
                isFullWidth: true,
                onPressed: onConfirm,
              ),
              const SizedBox(height: ViskaSpacing.spaceMd),
              ViskaButton(
                label: 'Divergente / Cancelar',
                style: ViskaButtonStyle.danger,
                isFullWidth: true,
                onPressed: onReject,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
