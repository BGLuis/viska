import 'package:flutter/material.dart';

/// Tema Dark-Tech Editorial de alta precisão para o Viska.
///
/// Paleta de cores com foco em segurança operacional, contraste e sobriedade:
/// - Fundo (Scaffold): `#0A0D10` (Obsidiana / Carbono Profundo)
/// - Superfícies: `#11151B` e `#181E27` (Ardósia Técnica)
/// - Primária: `#00E599` (Verde Menta Elétrico - Confiança / Verificado)
/// - Secundária: `#FFB800` (Âmbar Criptográfico - Efêmero / Timers)
/// - Alerta / Erro: `#FF3B30` (Carmim Aeroespacial)
/// - Divisórias: `#1E2530` (Linhas ultrafinas de alta precisão)
class DarkTechTheme {
  DarkTechTheme._();

  // Cores principais normativas
  static const Color scaffoldBackground = Color(0xFF0A0D10);
  static const Color surface = Color(0xFF11151B);
  static const Color surfaceContainer = Color(0xFF181E27);
  static const Color primary = Color(0xFF00E599);
  static const Color onPrimary = Color(0xFF0A0D10);
  static const Color secondary = Color(0xFFFFB800);
  static const Color onSecondary = Color(0xFF0A0D10);
  static const Color alert = Color(0xFFFF3B30);
  static const Color divider = Color(0xFF1E2530);

  // Tipografia e tons neutros
  static const Color textPrimary = Color(0xFFEDF2F7);
  static const Color textSecondary = Color(0xFF8A99AD);
  static const Color textMuted = Color(0xFF55657E);

  static ThemeData get theme {
    final colorScheme = const ColorScheme.dark().copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: Color(0xFF0A3D28),
      onPrimaryContainer: Color(0xFF6BFFC9),
      secondary: secondary,
      onSecondary: onSecondary,
      secondaryContainer: Color(0xFF3D2C00),
      onSecondaryContainer: Color(0xFFFFE082),
      error: alert,
      onError: Colors.white,
      errorContainer: Color(0xFF4A100E),
      onErrorContainer: Color(0xFFFFB4AB),
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      surfaceContainerHighest: surfaceContainer,
      outline: divider,
      outlineVariant: divider,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: scaffoldBackground,
      colorScheme: colorScheme,
      dividerColor: divider,
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 1.0,
        space: 1.0,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: Border(
          bottom: BorderSide(color: divider, width: 1.0),
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: divider, width: 1.0),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceContainer,
        hintStyle: const TextStyle(color: textMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: alert),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: divider, width: 1.0),
        ),
        titleTextStyle: const TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: divider, width: 1.0),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: onPrimary,
        elevation: 2,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: primary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: textPrimary,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
      ),
    );
  }
}
