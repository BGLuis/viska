import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_radii.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';

/// Pareamento recusado por chaves diferentes das já conferidas (Tela 17 do Figma).
///
/// Ganha tela própria, e não um aviso de rodapé, porque `contactKeyMismatch` é
/// o único erro de pareamento que pode indicar alguém se passando pelo contato.
class PairingRejectedScreen extends StatelessWidget {
  const PairingRejectedScreen({super.key, this.contactName});

  final String? contactName;

  static Future<void> show(BuildContext context, {String? contactName}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairingRejectedScreen(contactName: contactName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final who = contactName?.trim().isNotEmpty == true ? contactName!.trim() : 'esta pessoa';

    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(title: const Text('Adicionar contato')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: ViskaSpacing.space2xl),
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            color: ViskaColors.dangerContainer,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.warning_amber_rounded,
                            size: 40,
                            color: ViskaColors.dangerDefault,
                          ),
                        ),
                      ),
                      const SizedBox(height: ViskaSpacing.spaceLg),
                      Text(
                        'Pareamento recusado',
                        textAlign: TextAlign.center,
                        style: ViskaTypography.headline,
                      ),
                      const SizedBox(height: ViskaSpacing.spaceLg),
                      Text(
                        'Você já tem $who como contato, mas este código traz chaves '
                        'diferentes das que você conferiu antes. Por segurança, nada foi alterado.',
                        textAlign: TextAlign.center,
                        style: ViskaTypography.bodyMedium.copyWith(
                          color: ViskaColors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: ViskaSpacing.spaceLg),
                      Container(
                        padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
                        decoration: BoxDecoration(
                          color: ViskaColors.bgSurface,
                          borderRadius: ViskaRadii.borderLg,
                          border: Border.all(color: ViskaColors.borderDefault),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('O que pode ter acontecido', style: ViskaTypography.titleMedium),
                            const SizedBox(height: ViskaSpacing.spaceSm),
                            Text(
                              '• A pessoa trocou de aparelho ou reinstalou o app.\n'
                              '• Alguém está tentando se passar por ela.',
                              style: ViskaTypography.bodySmall.copyWith(
                                color: ViskaColors.textSecondary,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: ViskaSpacing.spaceSm),
                            Text(
                              'Confirme com ela pessoalmente antes de qualquer coisa.',
                              style: ViskaTypography.bodySmall.copyWith(
                                color: ViskaColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ViskaButton(
                label: 'Entendi',
                style: ViskaButtonStyle.secondary,
                isFullWidth: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
