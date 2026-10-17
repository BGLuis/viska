import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';

enum MessageDeliveryStatus {
  sending,
  sent,
  delivered,
  failed,
}

/// Ícone indicador de entrega da mensagem no chat.
class MessageStatusIcon extends StatelessWidget {
  const MessageStatusIcon({
    super.key,
    required this.status,
    this.size = 14.0,
  });

  final MessageDeliveryStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case MessageDeliveryStatus.sending:
        return Icon(
          Icons.access_time_rounded,
          size: size,
          color: ViskaColors.textMuted,
        );
      case MessageDeliveryStatus.sent:
        return Icon(
          Icons.check,
          size: size,
          color: ViskaColors.textSecondary,
        );
      case MessageDeliveryStatus.delivered:
        return Icon(
          Icons.done_all_rounded,
          size: size,
          color: ViskaColors.trustDefault,
        );
      case MessageDeliveryStatus.failed:
        return Icon(
          Icons.error_outline_rounded,
          size: size,
          color: ViskaColors.dangerDefault,
        );
    }
  }
}
