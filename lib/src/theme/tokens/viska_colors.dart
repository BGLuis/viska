import 'package:flutter/material.dart';

/// Tokens de cores semânticos do Viska extraídos da especificação Figma.
///
/// Modo escuro exclusivo voltado para alta segurança operacional,
/// legibilidade sob estresse e clareza de confiança criptográfica.
abstract final class ViskaColors {
  // Superfícies
  static const Color bgCanvas = Color(0xFF0A0D10);
  static const Color bgSurface = Color(0xFF11151B);
  static const Color bgSurfaceRaised = Color(0xFF181E27);
  static const Color bgPressed = Color(0xFF1E2530);
  static const Color bgScrim = Color(0x99000000);

  // Bordas e divisores
  static const Color borderDefault = Color(0xFF1E2530);
  static const Color borderStrong = Color(0xFF2A3341);

  // Tipografia e tons neutros
  static const Color textPrimary = Color(0xFFEDF2F7);
  static const Color textSecondary = Color(0xFF8A99AD);
  static const Color textMuted = Color(0xFF7D8CA3);

  // Confiança / Verificado (Menta Criptográfico)
  static const Color trustDefault = Color(0xFF00E599);
  static const Color trustOn = Color(0xFF0A0D10);
  static const Color trustContainer = Color(0xFF0A3D28);
  static const Color trustOnContainer = Color(0xFF6BFFC9);
  static const Color trustSubtle = Color(0x1F00E599);
  static const Color trustBorder = Color(0x5900E599);

  // Efêmero / Temporizadores (Âmbar)
  static const Color ephemeralDefault = Color(0xFFFFB800);
  static const Color ephemeralOn = Color(0xFF0A0D10);
  static const Color ephemeralContainer = Color(0xFF3D2C00);
  static const Color ephemeralOnContainer = Color(0xFFFFE082);
  static const Color ephemeralSubtle = Color(0x1FFFB800);

  // Perigo / Coação / Erro (Carmim Aeroespacial)
  static const Color dangerDefault = Color(0xFFFF3B30);
  static const Color dangerOn = Color(0xFF0A0D10);
  static const Color dangerContainer = Color(0xFF4A100E);
  static const Color dangerOnContainer = Color(0xFFFFB4AB);
  static const Color dangerSubtle = Color(0x29FF3B30);

  // Bolhas de Chat
  static const Color bubbleOutgoing = Color(0xFF181E27);
  static const Color bubbleOutgoingBorder = Color(0x5900E599);
  static const Color bubbleIncoming = Color(0xFF11151B);
  static const Color bubbleIncomingBorder = Color(0xFF1E2530);
}
