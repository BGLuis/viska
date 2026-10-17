import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Alternador segmentado de abas dark-tech de alta precisão.
class SegmentedTabs extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ViskaSpacing.space2xs),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurfaceRaised,
        borderRadius: ViskaRadii.borderMd,
        border: Border.all(color: ViskaColors.borderDefault),
      ),
      child: Row(
        children: List.generate(tabs.length, (index) {
          final isSelected = index == selectedIndex;

          return Expanded(
            child: GestureDetector(
              onTap: () => onTabSelected(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: ViskaSpacing.spaceSm),
                decoration: BoxDecoration(
                  color: isSelected ? ViskaColors.bgSurface : Colors.transparent,
                  borderRadius: ViskaRadii.borderSm,
                  border: isSelected
                      ? Border.all(color: ViskaColors.borderStrong)
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  tabs[index],
                  style: ViskaTypography.labelMedium.copyWith(
                    color: isSelected
                        ? ViskaColors.textPrimary
                        : ViskaColors.textMuted,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
