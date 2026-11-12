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
    // Biometria e PIN em paralelo podem terminar em qualquer ordem — por
    // exemplo, o cofre real abrir e um resultado de coação tardio trocar para o
    // cofre falso. Com a verificação do PIN levando ~1 s, a janela é real.
    if (_isAuthenticating || _isSubmitting) return;
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
    // Visível na tela: a verificação agora é uma derivação cara (issue #90) e
    // leva perto de um segundo num aparelho modesto.
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

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
      if (mounted) {
        setState(() => _isSubmitting = false);
      } else {
        _isSubmitting = false;
      }
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
    final reachesShorterPin =
        len == _controller.normalPinLength ||
        len == _controller.duressPinLength;
    if (len == _submitLength) {
      _submitPin();
    } else if (reachesShorterPin) {
      _submitIfShorterPinMatches();
    }
  }

  /// Configurações antigas, com PINs de tamanhos diferentes: no tamanho do mais
  /// curto só envia se ele coincidir. A verificação é uma derivação cara (issue
  /// #90) e roda sem bloquear a digitação: quem continua digitando o PIN mais
  /// longo não pode perder dígitos, e um resultado que chega depois de o PIN
  /// mudar é descartado pela comparação com `candidate`.
  Future<void> _submitIfShorterPinMatches() async {
    final candidate = _pin;
    var matches = false;
    try {
      matches = await _controller.matchesAnyPin(candidate);
    } catch (_) {
      // Falha na derivação equivale a não coincidir: o dono ainda alcança o
      // tamanho maior e o PIN é avaliado de novo no envio.
    }
    if (mounted && matches && _pin == candidate) await _submitPin();
  }

  void _onBackspacePressed() {
    if (_pin.isEmpty || _isSubmitting) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  /// Cabe duas linhas de `bodySmall`, o caso das mensagens mais longas.
  static const double _statusLineHeight = 40;

  Widget _buildStatusLine(bool isWaiting, Duration retryDelay) {
    final String? text;
    final Color color;
    Key? key;
    if (isWaiting) {
      text =
          'Muitas tentativas. Tente novamente em ${_formatRetryDelay(retryDelay)}.';
      color = ViskaColors.dangerDefault;
    } else if (_errorMessage != null) {
      text = _errorMessage;
      color = ViskaColors.dangerDefault;
    } else if (_isSubmitting) {
      text = 'Verificando PIN...';
      color = ViskaColors.textMuted;
      key = const Key('pin-verifying');
    } else {
      return const SizedBox.shrink();
    }
    return Text(
      text!,
      key: key,
      textAlign: TextAlign.center,
      maxLines: 2,
      style: ViskaTypography.bodySmall.copyWith(
        color: color,
        fontWeight: color == ViskaColors.dangerDefault ? FontWeight.w600 : null,
      ),
    );
  }

  String _formatRetryDelay(Duration delay) {
    final seconds = delay.inSeconds + (delay.inMilliseconds % 1000 > 0 ? 1 : 0);
    if (seconds < 60) return '$seconds s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0
        ? '$minutes min'
        : '$minutes min ${rest.toString().padLeft(2, '0')} s';
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
            padding: const EdgeInsets.symmetric(
              horizontal: ViskaSpacing.space2xl,
            ),
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
                Text('Viska Bloqueado', style: ViskaTypography.headline),
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

                // Uma só linha de status, de altura fixa: espera, erro ou
                // verificação. Linhas que aparecem e somem deslocariam o
                // teclado sob o dedo a cada envio.
                Semantics(
                  liveRegion: true,
                  child: SizedBox(
                    height: _statusLineHeight,
                    child: Center(
                      child: _buildStatusLine(isWaiting, retryDelay),
                    ),
                  ),
                ),
                const SizedBox(height: ViskaSpacing.spaceSm),

                if (hasPin) ...[
                  // Esmaecido enquanto o PIN é verificado: dígitos são
                  // ignorados nesse intervalo e o teclado não pode parecer ativo.
                  AnimatedOpacity(
                    opacity: _isSubmitting ? 0.5 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: PinPad(
                      keySize: 52.0,
                      onDigitPressed: _onDigitPressed,
                      onBackspacePressed: _onBackspacePressed,
                      leftAction: IconButton(
                        icon: const Icon(Icons.fingerprint, size: 24),
                        color: ViskaColors.trustDefault,
                        tooltip: 'Desbloquear com biometria',
                        onPressed: _isAuthenticating || _isSubmitting
                            ? null
                            : _authenticate,
                      ),
                    ),
                  ),
                  const SizedBox(height: ViskaSpacing.spaceSm),
                ],

                OutlinedButton.icon(
                  onPressed: _isAuthenticating || _isSubmitting
                      ? null
                      : _authenticate,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(
                    _isAuthenticating ? 'Verificando...' : 'Desbloquear',
                  ),
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
