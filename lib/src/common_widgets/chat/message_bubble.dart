import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import '../identity/message_status_icon.dart';

enum MessageType {
  text,
  voice,
  file,
  viewOnce,
  viewOnceOpened,
}

/// Bolha de mensagem do chat com as 10 variantes normativas do Figma.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.isOutgoing,
    required this.type,
    this.text,
    this.fileName,
    this.fileSubtitle,
    this.voiceDuration,
    this.waveformWidget,
    this.replyWidget,
    this.reactionsWidget,
    this.deliveryStatus = MessageDeliveryStatus.sent,
    this.isEphemeral = false,
    this.timestamp,
    this.onTap,
    this.onLongPress,
  });

  final bool isOutgoing;
  final MessageType type;
  final String? text;
  final String? fileName;
  final String? fileSubtitle;
  final String? voiceDuration;
  final Widget? waveformWidget;
  final Widget? replyWidget;
  final Widget? reactionsWidget;
  final MessageDeliveryStatus deliveryStatus;
  final bool isEphemeral;
  final String? timestamp;
  final VoidCallback? onTap;
  final void Function(Offset position)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final bgColor = isOutgoing
        ? ViskaColors.bubbleOutgoing
        : ViskaColors.bubbleIncoming;
    final borderColor = isOutgoing
        ? ViskaColors.bubbleOutgoingBorder
        : ViskaColors.bubbleIncomingBorder;

    Widget bodyContent;
    switch (type) {
      case MessageType.text:
        bodyContent = Text(
          text ?? '',
          style: ViskaTypography.bodyLarge.copyWith(
            fontSize: 14.5,
            color: ViskaColors.textPrimary,
          ),
        );
        break;
      case MessageType.voice:
        bodyContent = waveformWidget ??
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_arrow_rounded, color: ViskaColors.trustDefault),
                const SizedBox(width: ViskaSpacing.spaceSm),
                Text(
                  voiceDuration ?? '0:00',
                  style: ViskaTypography.monoSmall.copyWith(
                    color: ViskaColors.textPrimary,
                  ),
                ),
              ],
            );
        break;
      case MessageType.file:
        bodyContent = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.insert_drive_file_rounded,
              color: ViskaColors.trustDefault,
              size: 22,
            ),
            const SizedBox(width: ViskaSpacing.spaceSm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fileName ?? 'Arquivo',
                    style: ViskaTypography.bodyMedium.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (fileSubtitle != null)
                    Text(
                      fileSubtitle!,
                      style: ViskaTypography.bodySmall.copyWith(
                        color: ViskaColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
        break;
      case MessageType.viewOnce:
        bodyContent = Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ViskaSpacing.spaceMd,
            vertical: ViskaSpacing.spaceSm,
          ),
          decoration: BoxDecoration(
            color: ViskaColors.ephemeralSubtle,
            borderRadius: ViskaRadii.borderSm,
            border: Border.all(
              color: ViskaColors.ephemeralDefault,
              width: 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.looks_one_rounded,
                size: 18,
                color: ViskaColors.ephemeralDefault,
              ),
              const SizedBox(width: ViskaSpacing.spaceSm),
              Text(
                isOutgoing
                    ? 'Mensagem de visualização única enviada'
                    : 'Toque para abrir mensagem única',
                style: ViskaTypography.bodyMedium.copyWith(
                  color: ViskaColors.ephemeralOnContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
        break;
      case MessageType.viewOnceOpened:
        bodyContent = Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ViskaSpacing.spaceMd,
            vertical: ViskaSpacing.spaceSm,
          ),
          decoration: BoxDecoration(
            color: ViskaColors.bgCanvas,
            borderRadius: ViskaRadii.borderSm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.visibility_off_outlined,
                size: 16,
                color: ViskaColors.textMuted,
              ),
              const SizedBox(width: ViskaSpacing.spaceSm),
              Text(
                'Mensagem visualizada (autodestruída)',
                style: ViskaTypography.bodySmall.copyWith(
                  color: ViskaColors.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        );
        break;
    }

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onTap,
        onLongPressStart: onLongPress != null
            ? (details) => onLongPress!(details.globalPosition)
            : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(
            horizontal: ViskaSpacing.spaceMd,
            vertical: ViskaSpacing.spaceSm,
          ),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(isOutgoing ? 14 : 2),
              bottomRight: Radius.circular(isOutgoing ? 2 : 14),
            ),
            border: Border.all(
              color: borderColor,
              width: 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ?replyWidget,
              bodyContent,
              const SizedBox(height: ViskaSpacing.space2xs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (type == MessageType.viewOnce || type == MessageType.viewOnceOpened) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: const BoxDecoration(
                        color: ViskaColors.ephemeralSubtle,
                        borderRadius: ViskaRadii.borderXs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.looks_one_rounded,
                            size: 11,
                            color: ViskaColors.ephemeralDefault,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            'Única',
                            style: ViskaTypography.monoSmall.copyWith(
                              fontSize: 10,
                              color: ViskaColors.ephemeralDefault,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: ViskaSpacing.spaceXs),
                  ] else if (isEphemeral) ...[
                    const Icon(
                      Icons.timer_outlined,
                      size: 12,
                      color: ViskaColors.ephemeralDefault,
                    ),
                    const SizedBox(width: ViskaSpacing.spaceXs),
                  ],
                  if (timestamp != null) ...[
                    Text(
                      timestamp!,
                      style: ViskaTypography.bodySmall.copyWith(
                        fontSize: 10.5,
                        color: ViskaColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: ViskaSpacing.spaceXs),
                  ],
                  if (isOutgoing)
                    MessageStatusIcon(status: deliveryStatus),
                ],
              ),
              ?reactionsWidget,
            ],
          ),
        ),
      ),
    );
  }
}
