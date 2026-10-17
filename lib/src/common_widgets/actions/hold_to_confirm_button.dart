import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Botão de confirmação por pressão mantida (Hold-to-Confirm) de 2 segundos.
///
/// Projetado para operações destrutivas irreversíveis (Zona de Perigo / Apagamento de Emergência),
/// fornecendo feedback visual de progresso e vibração háptica contínua/final.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.holdDuration = const Duration(seconds: 2),
    this.icon = Icons.warning_amber_rounded,
    this.color = ViskaColors.dangerDefault,
    this.isFullWidth = true,
  });

  final String label;
  final VoidCallback onConfirmed;
  final Duration holdDuration;
  final IconData icon;
  final Color color;
  final bool isFullWidth;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.holdDuration,
    )
      ..addListener(_checkCompleted)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _checkCompleted();
        }
      });
  }

  void _startHolding() {
    if (_completed) return;
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}
    _controller.forward();
  }

  void _checkCompleted() {
    if ((_controller.isCompleted || _controller.value >= 1.0) && !_completed) {
      _completed = true;
      try {
        HapticFeedback.heavyImpact();
      } catch (_) {}
      widget.onConfirmed();
    }
  }

  void _stopHolding() {
    _checkCompleted();
    if (_completed || _controller.value >= 1.0) return;
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final widgetBody = Listener(
      onPointerDown: (_) => _startHolding(),
      onPointerUp: (_) => _stopHolding(),
      onPointerCancel: (_) => _stopHolding(),
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = _controller.value;
          final isHolding = progress > 0;

          return Container(
            height: 48,
            decoration: BoxDecoration(
              color: ViskaColors.dangerContainer,
              borderRadius: ViskaRadii.borderMd,
              border: Border.all(
                color: isHolding ? widget.color : widget.color.withAlpha(89),
                width: 1.5,
              ),
            ),
            child: Stack(
              children: [
                // Barra de progresso preenchendo o fundo
                if (progress > 0)
                  FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      decoration: BoxDecoration(
                        color: widget.color.withAlpha(128),
                        borderRadius: ViskaRadii.borderMd,
                      ),
                    ),
                  ),
                // Conteúdo central
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: ViskaSpacing.spaceLg),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 2.5,
                                backgroundColor: Colors.transparent,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  isHolding ? Colors.white : widget.color,
                                ),
                              ),
                              Icon(
                                widget.icon,
                                size: 14,
                                color: isHolding ? Colors.white : widget.color,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: ViskaSpacing.spaceSm),
                        Flexible(
                          child: Text(
                            isHolding
                                ? 'SEGURE POR ${(widget.holdDuration.inSeconds * (1 - progress)).toStringAsFixed(1)}s...'
                                : widget.label,
                            style: ViskaTypography.labelLarge.copyWith(
                              color: isHolding ? Colors.white : ViskaColors.dangerOnContainer,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (widget.isFullWidth) {
      return SizedBox(
        width: double.infinity,
        child: widgetBody,
      );
    }
    return widgetBody;
  }
}
