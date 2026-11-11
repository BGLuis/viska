import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_typography.dart';

enum ViskaAvatarSize {
  sm(32.0, 14.0, 10.0),
  md(40.0, 16.0, 12.0),
  lg(48.0, 20.0, 14.0),
  xl(64.0, 26.0, 18.0);

  const ViskaAvatarSize(this.dimension, this.fontSize, this.badgeSize);
  final double dimension;
  final double fontSize;
  final double badgeSize;
}

/// Avatar dark-tech com cálculo de inicial, variantes Contato vs Eu e selo acoplado.
class ViskaAvatar extends StatelessWidget {
  const ViskaAvatar({
    super.key,
    required this.name,
    this.size = ViskaAvatarSize.md,
    this.isVerified = false,
    this.isSelf = false,
  });

  final String name;
  final ViskaAvatarSize size;
  final bool isVerified;
  final bool isSelf;

  String _getInitials(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return trimmed[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final initials = _getInitials(name);

    final bgColor = isSelf
        ? ViskaColors.bgSurfaceRaised
        : ViskaColors.bgPressed;
    final fgColor = isSelf
        ? ViskaColors.trustDefault
        : ViskaColors.textPrimary;
    final borderColor = isVerified
        ? ViskaColors.trustBorder
        : ViskaColors.borderStrong;

    return SizedBox(
      width: size.dimension,
      height: size.dimension,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size.dimension,
            height: size.dimension,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: borderColor,
                width: isVerified ? 1.5 : 1.0,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: TextStyle(
                fontFamily: ViskaTypography.fontSans,
                fontSize: size.fontSize,
                fontWeight: FontWeight.w600,
                color: fgColor,
              ),
            ),
          ),
          if (isVerified)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size.badgeSize,
                height: size.badgeSize,
                decoration: BoxDecoration(
                  color: ViskaColors.trustDefault,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ViskaColors.bgCanvas,
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.check,
                  size: size.badgeSize * 0.7,
                  color: ViskaColors.trustOn,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
