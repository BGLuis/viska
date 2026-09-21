import 'package:flutter/material.dart';
import 'package:viska/src/features/lock/lock_controller.dart';

/// Envolve a árvore de widgets da aplicação para interceptar gestos e toques
/// do usuário e reiniciar o temporizador de inatividade do [LockController].
class InactivityDetector extends StatelessWidget {
  const InactivityDetector({
    super.key,
    required this.controller,
    required this.child,
  });

  final LockController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => controller.onUserInteraction(),
      onPointerMove: (_) => controller.onUserInteraction(),
      child: child,
    );
  }
}
