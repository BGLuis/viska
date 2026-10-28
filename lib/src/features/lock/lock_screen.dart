import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../common_widgets/security/pin_dots.dart';
import '../../common_widgets/security/pin_pad.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import 'lock_controller.dart';

/// Tela exibida quando o aplicativo está bloqueado (Telas 20 e 21 do Figma).
///
/// Todas as chaves e sessões em memória foram destruídas no Rust.
/// O usuário pode se autenticar biometricamente ou digitar o PIN (Normal ou Coação)
/// utilizando o teclado numérico in-app seguro.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});

  final LockController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  bool _isAuthenticating = false;
  bool _isSubmitting = false;
  String? _errorMessage;
  Timer? _retryTicker;

  LockController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _syncRetryTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  @override
  void dispose() {
    _retryTicker?.cancel();
    super.dispose();
  }

  /// Mantém a contagem regressiva da espera entre tentativas atualizada na tela.
  void _syncRetryTicker() {
    _retryTicker?.cancel();
    if (_controller.pinRetryDelay == Duration.zero) return;
    _retryTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {});
      if (_controller.pinRetryDelay == Duration.zero) timer.cancel();
    });
  }

  Future<void> _authenticate() async {
    if (_isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    final success = await _controller.unlock();

    if (!mounted) return;
    setState(() {
      _isAuthenticating = false;
      if (!success) {
        _errorMessage = 'Falha na autenticação ou cofre indisponível.';
      }
    });
  }

  Future<void> _submitPin() async {
    if (_pin.isEmpty || _isSubmitting) return;
    _isSubmitting = true;
    setState(() => _errorMessage = null);

    try {
      final success = await _controller.verifyAndUnlockWithPin(_pin);
      if (!mounted) return;
      if (!success) {
        setState(() {
          _errorMessage = 'PIN incorreto';
          _pin = '';
        });
        _syncRetryTicker();
      }
    } finally {
      _isSubmitting = false;
    }
  }

  /// Tamanho em que o PIN é enviado sem confirmação. Configurações novas têm
  /// os dois PINs do mesmo tamanho; nas antigas vale o maior, para que o mais
  /// longo continue alcançável.
  int get _submitLength => max(
        _controller.normalPinLength ?? LockController.minPinLength,
        _controller.duressPinLength ?? 0,
      );

  void _onDigitPressed(String digit) {
    if (_isSubmitting || _controller.pinRetryDelay > Duration.zero) return;
    if (_pin.length >= _submitLength) return;
    setState(() {
      _pin += digit;
      _errorMessage = null;
    });

    final len = _pin.length;
    final reachesShorterPin = len == _controller.normalPinLength ||
        len == _controller.duressPinLength;
    if (len == _submitLength ||
        (reachesShorterPin && _controller.matchesAnyPin(_pin))) {
      _submitPin();
    }
  }

  void _onBackspacePressed() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  String _formatRetryDelay(Duration delay) {
    final seconds = delay.inSeconds + (delay.inMilliseconds % 1000 > 0 ? 1 : 0);
    if (seconds < 60) return '$seconds s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '$minutes min' : '$minutes min ${rest.toString().padLeft(2, '0')} s';
  }

  @override
  Widget build(BuildContext context) {
    final hasPin = _controller.hasNormalPin;
    final retryDelay = _controller.pinRetryDelay;
    final isWaiting = hasPin && retryDelay > Duration.zero;
    final hasError = _errorMessage != null || isWaiting;

    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: ViskaSpacing.space2xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: ViskaSpacing.spaceSm),
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: ViskaColors.bgSurfaceRaised,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: hasError
                          ? ViskaColors.dangerDefault
                          : ViskaColors.borderStrong,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 28,
                    color: hasError
                          ? ViskaColors.dangerDefault
                          : ViskaColors.textSecondary,
                  ),
                ),
                const SizedBox(height: ViskaSpacing.spaceSm),
                Text(
                  'Viska Bloqueado',
                  style: ViskaTypography.headline,
                ),
                const SizedBox(height: 4),
                Text(
                  'Chaves destruídas em memória e cofre lacrado.',
                  textAlign: TextAlign.center,
                  style: ViskaTypography.bodySmall.copyWith(
                    color: ViskaColors.textMuted,
                  ),
                ),
                const SizedBox(height: ViskaSpacing.spaceMd),

                // Sem PIN cadastrado não há o que digitar: só a autenticação do sistema.
                if (hasPin) ...[
                  PinDots(
                    length: _submitLength,
                    filledCount: _pin.length,
                    hasError: hasError,
                  ),
                  const SizedBox(height: ViskaSpacing.spaceSm),
                ],

                if (isWaiting || _errorMessage != null) ...[
                  Text(
                    isWaiting
                        ? 'Muitas tentativas. Tente novamente em ${_formatRetryDelay(retryDelay)}.'
                        : _errorMessage!,
                    textAlign: TextAlign.center,
                    style: ViskaTypography.bodySmall.copyWith(
                      color: ViskaColors.dangerDefault,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: ViskaSpacing.spaceSm),
                ],

                if (hasPin) ...[
                  PinPad(
                    keySize: 52.0,
                    onDigitPressed: _onDigitPressed,
                    onBackspacePressed: _onBackspacePressed,
                    leftAction: IconButton(
                      icon: const Icon(Icons.fingerprint, size: 24),
                      color: ViskaColors.trustDefault,
                      tooltip: 'Desbloquear com biometria',
                      onPressed: _isAuthenticating ? null : _authenticate,
                    ),
                  ),
                  const SizedBox(height: ViskaSpacing.spaceSm),
                ],

                OutlinedButton.icon(
                  onPressed: _isAuthenticating ? null : _authenticate,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(_isAuthenticating ? 'Verificando...' : 'Desbloquear'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ViskaColors.trustDefault,
                    side: const BorderSide(color: ViskaColors.borderStrong),
                    padding: const EdgeInsets.symmetric(
                      horizontal: ViskaSpacing.space2xl,
                      vertical: ViskaSpacing.spaceSm,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
