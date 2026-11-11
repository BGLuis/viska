import 'package:flutter/material.dart';
import 'tokens/viska_colors.dart';
import 'tokens/viska_radii.dart';
import 'tokens/viska_spacing.dart';
import 'tokens/viska_typography.dart';

export 'tokens/viska_colors.dart';
export 'tokens/viska_radii.dart';
export 'tokens/viska_spacing.dart';
export 'tokens/viska_typography.dart';

/// Tema Dark-Tech Editorial de alta precisão para o Viska.
///
/// Paleta de cores com foco em segurança operacional, contraste e sobriedade:
/// - Fundo (Scaffold): `#0A0D10` (ViskaColors.bgCanvas)
/// - Superfícies: `#11151B` e `#181E27` (ViskaColors.bgSurface e bgSurfaceRaised)
/// - Primária: `#00E599` (Verde Menta Elétrico - Confiança / Verificado)
/// - Secundária: `#FFB800` (Âmbar Criptográfico - Efêmero / Timers)
/// - Alerta / Erro: `#FF3B30` (Carmim Aeroespacial)
/// - Divisórias: `#1E2530` (Linhas ultrafinas de alta precisão)
class DarkTechTheme {
  DarkTechTheme._();

  // Cores principais normativas (espelhadas de ViskaColors para compatibilidade)
  static const Color scaffoldBackground = ViskaColors.bgCanvas;
  static const Color surface = ViskaColors.bgSurface;
  static const Color surfaceContainer = ViskaColors.bgSurfaceRaised;
  static const Color primary = ViskaColors.trustDefault;
  static const Color onPrimary = ViskaColors.trustOn;
  static const Color secondary = ViskaColors.ephemeralDefault;
  static const Color onSecondary = ViskaColors.ephemeralOn;
  static const Color alert = ViskaColors.dangerDefault;
  static const Color divider = ViskaColors.borderDefault;

  // Tipografia e tons neutros
  static const Color textPrimary = ViskaColors.textPrimary;
  static const Color textSecondary = ViskaColors.textSecondary;
  static const Color textMuted = ViskaColors.textMuted;

  static ThemeData get theme {
    const colorScheme = ColorScheme.dark(
      primary: ViskaColors.trustDefault,
      onPrimary: ViskaColors.trustOn,
      primaryContainer: ViskaColors.trustContainer,
      onPrimaryContainer: ViskaColors.trustOnContainer,
      secondary: ViskaColors.ephemeralDefault,
      onSecondary: ViskaColors.ephemeralOn,
      secondaryContainer: ViskaColors.ephemeralContainer,
      onSecondaryContainer: ViskaColors.ephemeralOnContainer,
      error: ViskaColors.dangerDefault,
      onError: ViskaColors.dangerOn,
      errorContainer: ViskaColors.dangerContainer,
      onErrorContainer: ViskaColors.dangerOnContainer,
      surface: ViskaColors.bgSurface,
      onSurface: ViskaColors.textPrimary,
      onSurfaceVariant: ViskaColors.textSecondary,
      surfaceContainerHighest: ViskaColors.bgSurfaceRaised,
      outline: ViskaColors.borderDefault,
      outlineVariant: ViskaColors.borderStrong,
    );

    final baseTextTheme = Typography.material2021().white.apply(
      fontFamily: ViskaTypography.fontSans,
      bodyColor: ViskaColors.textPrimary,
      displayColor: ViskaColors.textPrimary,
    );

    final textTheme = baseTextTheme.copyWith(
      displayLarge: ViskaTypography.display,
      headlineMedium: ViskaTypography.headline,
      titleLarge: ViskaTypography.titleLarge,
      titleMedium: ViskaTypography.titleMedium,
      bodyLarge: ViskaTypography.bodyLarge,
      bodyMedium: ViskaTypography.bodyMedium,
      bodySmall: ViskaTypography.bodySmall,
      labelLarge: ViskaTypography.labelLarge,
      labelMedium: ViskaTypography.labelMedium,
      labelSmall: ViskaTypography.labelOverline,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: ViskaTypography.fontSans,
      scaffoldBackgroundColor: ViskaColors.bgCanvas,
      colorScheme: colorScheme,
      textTheme: textTheme,
      dividerColor: ViskaColors.borderDefault,
      dividerTheme: const DividerThemeData(
        color: ViskaColors.borderDefault,
        thickness: 1.0,
        space: 1.0,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ViskaColors.bgSurface,
        foregroundColor: ViskaColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: Border(
          bottom: BorderSide(color: ViskaColors.borderDefault, width: 1.0),
        ),
        iconTheme: IconThemeData(color: ViskaColors.textPrimary),
        titleTextStyle: ViskaTypography.titleMedium,
      ),
      cardTheme: CardThemeData(
        color: ViskaColors.bgSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: ViskaRadii.borderMd,
          side: const BorderSide(color: ViskaColors.borderDefault, width: 1.0),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ViskaColors.bgSurfaceRaised,
        hintStyle: const TextStyle(
          color: ViskaColors.textMuted,
          fontFamily: ViskaTypography.fontSans,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: ViskaSpacing.spaceLg,
          vertical: ViskaSpacing.spaceMd,
        ),
        border: OutlineInputBorder(
          borderRadius: ViskaRadii.borderMd,
          borderSide: const BorderSide(color: ViskaColors.borderDefault),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: ViskaRadii.borderMd,
          borderSide: const BorderSide(color: ViskaColors.borderDefault),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: ViskaRadii.borderMd,
          borderSide: const BorderSide(color: ViskaColors.trustDefault, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: ViskaRadii.borderMd,
          borderSide: const BorderSide(color: ViskaColors.dangerDefault),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ViskaColors.bgSurface,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: ViskaRadii.borderLg,
          side: const BorderSide(color: ViskaColors.borderDefault, width: 1.0),
        ),
        titleTextStyle: ViskaTypography.titleLarge,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: ViskaColors.bgSurface,
        modalBackgroundColor: ViskaColors.bgSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(ViskaRadii.xl)),
          side: BorderSide(color: ViskaColors.borderDefault, width: 1.0),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: ViskaColors.trustDefault,
        foregroundColor: ViskaColors.trustOn,
        elevation: 2,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ViskaColors.trustDefault,
          foregroundColor: ViskaColors.trustOn,
          shape: RoundedRectangleBorder(
            borderRadius: ViskaRadii.borderMd,
          ),
          textStyle: ViskaTypography.labelLarge.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ViskaColors.trustDefault,
          side: const BorderSide(color: ViskaColors.trustDefault),
          shape: RoundedRectangleBorder(
            borderRadius: ViskaRadii.borderMd,
          ),
          textStyle: ViskaTypography.labelLarge.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ViskaColors.trustDefault,
          textStyle: ViskaTypography.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: ViskaColors.textPrimary,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: ViskaColors.textSecondary,
        textColor: ViskaColors.textPrimary,
      ),
    );
  }
}
