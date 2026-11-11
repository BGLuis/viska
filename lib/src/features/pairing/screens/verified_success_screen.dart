import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/identity/status_chip.dart';
import '../../../common_widgets/identity/viska_avatar.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';

/// Confirmação de contato verificado (Tela 19 do Figma).
///
/// Devolve `true` pelo `Navigator` quando o usuário escolhe abrir a conversa.
class VerifiedSuccessScreen extends StatelessWidget {
  const VerifiedSuccessScreen({super.key, required this.contactName});

  final String contactName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(title: Text('Verificar $contactName')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
                child: ViskaAvatar(
                  name: contactName,
                  size: ViskaAvatarSize.xl,
                  isVerified: true,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              Text(
                contactName,
                textAlign: TextAlign.center,
                style: ViskaTypography.headline,
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                'Vocês conferiram as chaves pessoalmente. Se elas mudarem um dia, '
                'o Viska avisa e bloqueia o envio até nova verificação.',
                textAlign: TextAlign.center,
                style: ViskaTypography.bodyMedium.copyWith(
                  color: ViskaColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              const Center(
                child: StatusChip(
                  label: 'Verificado agora',
                  icon: Icons.verified_rounded,
                  tone: StatusChipTone.trust,
                ),
              ),
              const Spacer(flex: 2),
              ViskaButton(
                label: 'Abrir conversa',
                isFullWidth: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
