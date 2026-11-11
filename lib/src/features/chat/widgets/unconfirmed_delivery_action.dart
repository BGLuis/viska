import 'package:flutter/material.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Rodapé de uma mensagem cuja entrega ficou incerta: o texto saiu do Rust, mas
/// o app fechou antes de saber se o transporte o entregou.
///
/// O reenvio nunca é automático. Se a primeira cópia tinha chegado, o contato
/// pode ver a mensagem duas vezes, e só a pessoa pode decidir correr esse risco.
class UnconfirmedDeliveryAction extends StatelessWidget {
  const UnconfirmedDeliveryAction({
    super.key,
    required this.label,
    required this.onResend,
  });

  final String label;
  final VoidCallback onResend;

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reenviar mensagem?'),
        content: const Text(
          'Não sabemos se esta mensagem chegou ao contato. Se ela já tiver chegado, '
          'ele verá a mensagem duas vezes.',
        ),
        actions: [
          TextButton(
            key: const Key('resend_unknown_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            key: const Key('resend_unknown_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reenviar'),
          ),
        ],
      ),
    );
    if (confirmed == true) onResend();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            color: DarkTechTheme.textMuted,
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          key: const Key('resend_unknown_button'),
          onTap: () => _confirm(context),
          child: const Text(
            'Reenviar',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              color: DarkTechTheme.secondary,
            ),
          ),
        ),
      ],
    );
  }
}
