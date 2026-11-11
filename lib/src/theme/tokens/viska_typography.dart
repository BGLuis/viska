import 'package:flutter/material.dart';
import 'viska_colors.dart';

/// Escala tipográfica canônica do Viska especificada no Figma.
///
/// `Inter` para toda a interface editorial e `JetBrains Mono` para
/// valores criptográficos inspecionados caractere a caractere.
abstract final class ViskaTypography {
  static const String fontSans = 'Inter';
  static const String fontMono = 'JetBrains Mono';

  // Display e Títulos (Inter SemiBold)
  static const TextStyle display = TextStyle(
    fontFamily: fontSans,
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w600,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle headline = TextStyle(
    fontFamily: fontSans,
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w600,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle titleLarge = TextStyle(
    fontFamily: fontSans,
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w600,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle titleMedium = TextStyle(
    fontFamily: fontSans,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w600,
    color: ViskaColors.textPrimary,
  );

  // Corpo de texto (Inter Regular)
  static const TextStyle bodyLarge = TextStyle(
    fontFamily: fontSans,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontFamily: fontSans,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle bodySmall = TextStyle(
    fontFamily: fontSans,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
    color: ViskaColors.textSecondary,
  );

  // Rótulos e Botões (Inter Medium & SemiBold)
  static const TextStyle labelLarge = TextStyle(
    fontFamily: fontSans,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w500,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle labelMedium = TextStyle(
    fontFamily: fontSans,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w500,
    color: ViskaColors.textSecondary,
  );

  static const TextStyle labelOverline = TextStyle(
    fontFamily: fontSans,
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: ViskaColors.textMuted,
  );

  // Monoespaçado (JetBrains Mono para hashes, fingerprints e números de segurança)
  static const TextStyle monoLarge = TextStyle(
    fontFamily: fontMono,
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w500,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle monoMedium = TextStyle(
    fontFamily: fontMono,
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w400,
    color: ViskaColors.textPrimary,
  );

  static const TextStyle monoSmall = TextStyle(
    fontFamily: fontMono,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
    color: ViskaColors.textSecondary,
  );
}
