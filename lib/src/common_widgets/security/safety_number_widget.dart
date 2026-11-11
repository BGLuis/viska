import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Exibição estilizada do Safety Number do Viska conforme o Figma.
///
/// Apresenta 12 blocos de 5 dígitos em JetBrains Mono e a seção
/// "Ou leia em voz alta" com as 6 palavras BIP-39 PT-BR.
class SafetyNumberWidget extends StatelessWidget {
  const SafetyNumberWidget({
    super.key,
    required this.digits,
    required this.words,
  });

  final String digits;
  final String words;

  @override
  Widget build(BuildContext context) {
    final digitGroups = digits.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final wordList = words.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
          decoration: BoxDecoration(
            color: ViskaColors.bgSurfaceRaised,
            borderRadius: ViskaRadii.borderMd,
            border: Border.all(color: ViskaColors.borderDefault),
          ),
          child: Wrap(
            key: const ValueKey('safety_number_digits'),
            alignment: WrapAlignment.center,
            spacing: ViskaSpacing.spaceMd,
            runSpacing: ViskaSpacing.spaceSm,
            children: [
              for (final group in digitGroups)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ViskaSpacing.spaceSm,
                    vertical: ViskaSpacing.space2xs,
                  ),
                  decoration: BoxDecoration(
                    color: ViskaColors.bgCanvas,
                    borderRadius: ViskaRadii.borderXs,
                    border: Border.all(color: ViskaColors.borderStrong),
                  ),
                  child: Text(
                    group,
                    style: ViskaTypography.monoMedium.copyWith(
                      fontWeight: FontWeight.w600,
                      color: ViskaColors.textPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (wordList.isNotEmpty) ...[
          const SizedBox(height: ViskaSpacing.spaceLg),
          Text(
            'OU LEIA EM VOZ ALTA',
            style: ViskaTypography.labelOverline,
          ),
          const SizedBox(height: ViskaSpacing.spaceSm),
          Container(
            padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
            decoration: BoxDecoration(
              color: ViskaColors.bgSurfaceRaised,
              borderRadius: ViskaRadii.borderMd,
              border: Border.all(color: ViskaColors.borderDefault),
            ),
            child: Wrap(
              key: const ValueKey('safety_number_words'),
              alignment: WrapAlignment.center,
              spacing: ViskaSpacing.spaceSm,
              runSpacing: ViskaSpacing.spaceSm,
              children: [
                for (final word in wordList)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ViskaSpacing.spaceSm,
                      vertical: ViskaSpacing.space2xs,
                    ),
                    decoration: BoxDecoration(
                      color: ViskaColors.bgCanvas,
                      borderRadius: ViskaRadii.borderXs,
                    ),
                    child: Text(
                      word,
                      style: ViskaTypography.bodyMedium.copyWith(
                        fontStyle: FontStyle.italic,
                        color: ViskaColors.trustOnContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
