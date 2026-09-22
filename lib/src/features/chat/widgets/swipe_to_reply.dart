import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Componente que envolve um balão de mensagem e escuta gestos de arrasto horizontal.
/// Quando o usuário desliza para a direita além do limite estipulado, ativa o callback [onReply].
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late Animation<double> _animOffset;

  double _dragOffset = 0.0;
  bool _thresholdReached = false;
  static const double _kThreshold = 46.0;
  static const double _kMaxDrag = 72.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _animOffset = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    )..addListener(() {
        setState(() => _dragOffset = _animOffset.value);
      });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;

    // Só permite deslizar para a direita
    final newOffset = _dragOffset + details.delta.dx;
    if (newOffset < 0) {
      if (_dragOffset != 0) {
        setState(() => _dragOffset = 0);
      }
      return;
    }

    // Amortecimento logarítmico para sensação elástica
    final clamped = math.min(newOffset, _kMaxDrag);
    if (!_thresholdReached && clamped >= _kThreshold) {
      _thresholdReached = true;
      HapticFeedback.lightImpact();
    } else if (_thresholdReached && clamped < _kThreshold) {
      _thresholdReached = false;
    }

    setState(() => _dragOffset = clamped);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;

    if (_thresholdReached) {
      widget.onReply();
    }

    _thresholdReached = false;
    _animOffset = Tween<double>(begin: _dragOffset, end: 0.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward(from: 0.0);
  }

  void _onHorizontalDragCancel() {
    if (!widget.enabled) return;
    _thresholdReached = false;
    _animOffset = Tween<double>(begin: _dragOffset, end: 0.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragOffset / _kThreshold).clamp(0.0, 1.0);

    return GestureDetector(
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: _onHorizontalDragCancel,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          // Ícone indicador de resposta que surge atrás do balão
          if (_dragOffset > 0)
            Positioned(
              left: math.max(0, _dragOffset - 36),
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: 0.6 + (0.4 * progress),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _thresholdReached
                          ? DarkTechTheme.primary
                          : DarkTechTheme.surfaceContainer,
                      border: Border.all(
                        color: _thresholdReached
                            ? DarkTechTheme.primary
                            : DarkTechTheme.divider,
                        width: 1.2,
                      ),
                    ),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 18,
                      color: _thresholdReached
                          ? DarkTechTheme.onPrimary
                          : DarkTechTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),

          // Balão de mensagem transladado
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
