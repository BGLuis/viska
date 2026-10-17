import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_radii.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';

/// Tela comemorativa de contato verificado com sucesso (Tela 19 do Figma).
class VerifiedSuccessScreen extends StatelessWidget {
  const VerifiedSuccessScreen({
    super.key,
    required this.contactName,
    this.onStartChat,
  });

  final String contactName;
  final VoidCallback? onStartChat;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(ViskaSpacing.space2xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: ViskaColors.trustContainer,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ViskaColors.trustDefault,
                      width: 2.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: ViskaColors.trustDefault.withAlpha(50),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.verified_rounded,
                    size: 52,
                    color: ViskaColors.trustDefault,
                  ),
                ),
              ),
              const SizedBox(height: ViskaSpacing.space2xl),
              Text(
                'Identidade Verificada',
                textAlign: TextAlign.center,
                style: ViskaTypography.headline.copyWith(
                  color: ViskaColors.trustDefault,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                'A chave de $contactName foi confirmada com sucesso.',
                textAlign: TextAlign.center,
                style: ViskaTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              Container(
                padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
                decoration: BoxDecoration(
                  color: ViskaColors.bgSurfaceRaised,
                  borderRadius: ViskaRadii.borderLg,
                  border: Border.all(color: ViskaColors.borderDefault),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.lock_outline_rounded,
                          size: 20,
                          color: ViskaColors.trustDefault,
                        ),
                        const SizedBox(width: ViskaSpacing.spaceSm),
                        Text(
                          'PROTEÇÃO CONTRA INTERCEPTAÇÃO',
                          style: ViskaTypography.labelOverline.copyWith(
                            color: ViskaColors.trustDefault,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: ViskaSpacing.spaceSm),
                    Text(
                      'Todas as mensagens, notas de voz e arquivos trocados com este contato agora utilizam autenticação criptográfica imutável validada por você.',
                      style: ViskaTypography.bodySmall.copyWith(
                        color: ViskaColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              ViskaButton(
                label: 'INICIAR CONVERSA SEGURA',
                style: ViskaButtonStyle.primary,
                isFullWidth: true,
                onPressed: () {
                  if (onStartChat != null) {
                    onStartChat!();
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
