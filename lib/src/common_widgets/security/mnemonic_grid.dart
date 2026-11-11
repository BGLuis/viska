import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Grade organizada das 24 palavras mnemônicas de recuperação (BIP-39).
///
/// Propositalmente NÃO inclui botão de "Copiar para Área de Transferência"
/// para proteger o segredo de keyloggers e interceptação do sistema operacional.
class MnemonicGrid extends StatelessWidget {
  const MnemonicGrid({
    super.key,
    required this.words,
  });

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurfaceRaised,
        borderRadius: ViskaRadii.borderMd,
        border: Border.all(color: ViskaColors.borderDefault),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: words.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 3.6,
          crossAxisSpacing: ViskaSpacing.spaceSm,
          mainAxisSpacing: ViskaSpacing.spaceSm,
        ),
        itemBuilder: (context, index) {
          final numberStr = (index + 1).toString().padLeft(2, '0');
          final word = words[index];

          return Container(
            padding: const EdgeInsets.symmetric(
              horizontal: ViskaSpacing.spaceMd,
              vertical: ViskaSpacing.spaceXs,
            ),
            decoration: BoxDecoration(
              color: ViskaColors.bgCanvas,
              borderRadius: ViskaRadii.borderSm,
              border: Border.all(color: ViskaColors.borderStrong),
            ),
            child: Row(
              children: [
                Text(
                  numberStr,
                  style: ViskaTypography.monoSmall.copyWith(
                    color: ViskaColors.textMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: ViskaSpacing.spaceSm),
                Expanded(
                  child: Text(
                    word,
                    style: ViskaTypography.monoMedium.copyWith(
                      color: ViskaColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
