import 'package:flutter/material.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Cabeçalho de seção de lista com tipografia labelOverline normativa do Figma.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      ViskaSpacing.spaceLg,
      ViskaSpacing.spaceXl,
      ViskaSpacing.spaceLg,
      ViskaSpacing.spaceSm,
    ),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title.toUpperCase(),
            style: ViskaTypography.labelOverline,
          ),
          ?trailing,
        ],
      ),
    );
  }
}
