import 'package:flutter/material.dart';
import '../../common_widgets/actions/viska_button.dart';
import '../../common_widgets/inputs/viska_text_field.dart';
import '../../rust/ffi/core.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Tela cheia de Onboarding e criação de identidade criptográfica (Tela 01 do Figma).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.core,
    this.onCompleted,
  });

  final Core core;
  final VoidCallback? onCompleted;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _nicknameController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _handleInitialize() async {
    final name = _nicknameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Informe seu nome ou pseudônimo.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.core.setMyNickname(nickname: name);
      if (!mounted) return;
      if (widget.onCompleted != null) {
        widget.onCompleted!();
      } else {
        Navigator.of(context).pop(name);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Falha ao gravar identidade criptográfica.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: ViskaSpacing.space2xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Ícone de Escudo Criptográfico
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: ViskaColors.trustContainer,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: ViskaColors.trustBorder,
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.shield_outlined,
                      size: 38,
                      color: ViskaColors.trustDefault,
                    ),
                  ),
                ),
                const SizedBox(height: ViskaSpacing.space2xl),

                // Título e Manifesto Editorial
                Text(
                  'Viska',
                  textAlign: TextAlign.center,
                  style: ViskaTypography.display.copyWith(
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: ViskaSpacing.spaceSm),
                Text(
                  'Comunicação direta 1:1 com criptografia híbrida pós-quântica (ML-KEM-768 + X25519) e zero servidores confiáveis.',
                  textAlign: TextAlign.center,
                  style: ViskaTypography.bodyMedium.copyWith(
                    color: ViskaColors.textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: ViskaSpacing.space3xl),

                // Card de entrada de identidade
                Container(
                  padding: const EdgeInsets.all(ViskaSpacing.spaceXl),
                  decoration: BoxDecoration(
                    color: ViskaColors.bgSurface,
                    borderRadius: ViskaRadii.borderLg,
                    border: Border.all(color: ViskaColors.borderDefault),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CRIAR SUA IDENTIDADE',
                        style: ViskaTypography.labelOverline,
                      ),
                      const SizedBox(height: ViskaSpacing.spaceMd),
                      ViskaTextField(
                        controller: _nicknameController,
                        labelText: 'Como você deseja ser chamado?',
                        hintText: 'Ex: Alice ou pseudônimo',
                        errorText: _errorMessage,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _handleInitialize(),
                      ),
                      const SizedBox(height: ViskaSpacing.spaceMd),
                      Text(
                        'Seu nome nunca transita pela nuvem. Ele é compartilhado ponto a ponto apenas no pareamento presencial por QR Code.',
                        style: ViskaTypography.bodySmall.copyWith(
                          color: ViskaColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: ViskaSpacing.space2xl),

                // Botão de Inicializar
                ViskaButton(
                  label: 'INICIALIZAR IDENTIDADE',
                  isFullWidth: true,
                  isLoading: _isLoading,
                  onPressed: _handleInitialize,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
