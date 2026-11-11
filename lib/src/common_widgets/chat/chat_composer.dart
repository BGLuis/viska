import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import '../actions/viska_icon_button.dart';

enum ComposerState {
  idle,
  typing,
  viewOnce,
  recording,
  locked,
}

/// Barra de composição e envio de mensagens e áudio do chat Dark-Tech.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.textController,
    required this.isViewOnce,
    required this.isRecording,
    required this.isMicLocked,
    required this.recordSeconds,
    required this.onToggleViewOnce,
    required this.onAttachFile,
    required this.onSendText,
    required this.onStartRecording,
    required this.onMicDragUpdate,
    required this.onMicDragEnd,
    required this.onCancelRecording,
    required this.onStopAndSendRecording,
    this.isSending = false,
    this.isSendingFile = false,
    this.isSendingVoice = false,
  });

  final TextEditingController textController;
  final bool isViewOnce;
  final bool isRecording;
  final bool isMicLocked;
  final int recordSeconds;
  final VoidCallback onToggleViewOnce;
  final VoidCallback? onAttachFile;
  final VoidCallback? onSendText;
  final VoidCallback onStartRecording;
  final void Function(double dx, double dy) onMicDragUpdate;
  final VoidCallback onMicDragEnd;
  final VoidCallback onCancelRecording;
  final VoidCallback onStopAndSendRecording;
  final bool isSending;
  final bool isSendingFile;
  final bool isSendingVoice;

  Widget _buildRecordingBar(BuildContext context) {
    final minutes = (recordSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (recordSeconds % 60).toString().padLeft(2, '0');

    return Container(
      margin: const EdgeInsets.fromLTRB(
        ViskaSpacing.spaceSm,
        ViskaSpacing.spaceXs,
        ViskaSpacing.spaceSm,
        ViskaSpacing.spaceSm,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: ViskaSpacing.spaceMd,
        vertical: ViskaSpacing.spaceSm,
      ),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurfaceRaised,
        borderRadius: ViskaRadii.borderLg,
        border: Border.all(
          color: ViskaColors.dangerDefault.withAlpha(128),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: ViskaColors.dangerDefault,
            ),
          ),
          const SizedBox(width: ViskaSpacing.spaceSm),
          Text(
            '$minutes:$seconds',
            style: ViskaTypography.monoMedium.copyWith(
              color: ViskaColors.dangerDefault,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: ViskaSpacing.spaceLg),
          Expanded(
            child: Text(
              isMicLocked ? 'Gravação travada' : '← Cancela  •  ↑ Trava',
              style: ViskaTypography.bodySmall.copyWith(
                color: ViskaColors.textSecondary,
              ),
            ),
          ),
          ViskaIconButton(
            icon: Icons.delete_outline_rounded,
            variant: ViskaIconButtonVariant.danger,
            tooltip: 'Cancelar gravação',
            onPressed: onCancelRecording,
          ),
          if (isMicLocked) ...[
            const SizedBox(width: ViskaSpacing.spaceXs),
            ViskaIconButton(
              icon: Icons.send_rounded,
              variant: ViskaIconButtonVariant.trust,
              tooltip: 'Enviar nota de voz',
              onPressed: onStopAndSendRecording,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ViskaSpacing.spaceSm,
        ViskaSpacing.spaceXs,
        ViskaSpacing.spaceSm,
        ViskaSpacing.spaceSm,
      ),
      child: Row(
        children: [
          ViskaIconButton(
            key: const Key('attach_file_button'),
            icon: Icons.attach_file_rounded,
            variant: ViskaIconButtonVariant.trust,
            tooltip: 'Enviar arquivo',
            onPressed: isSendingFile ? null : onAttachFile,
          ),
          const SizedBox(width: ViskaSpacing.spaceXs),
          IconButton(
            tooltip: isViewOnce ? 'Visualização única ativa' : 'Ativar visualização única',
            icon: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isViewOnce
                    ? ViskaColors.ephemeralContainer
                    : Colors.transparent,
                border: Border.all(
                  color: isViewOnce ? ViskaColors.ephemeralDefault : ViskaColors.borderStrong,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '1',
                style: ViskaTypography.labelMedium.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isViewOnce ? ViskaColors.ephemeralDefault : ViskaColors.textSecondary,
                ),
              ),
            ),
            onPressed: onToggleViewOnce,
          ),
          const SizedBox(width: ViskaSpacing.spaceXs),
          Expanded(
            child: TextField(
              controller: textController,
              autocorrect: false,
              enableSuggestions: false,
              style: ViskaTypography.bodyMedium,
              cursorColor: ViskaColors.trustDefault,
              decoration: InputDecoration(
                hintText: isViewOnce ? 'Mensagem de visualização única…' : 'Mensagem criptografada…',
                hintStyle: ViskaTypography.bodyMedium.copyWith(
                  color: isViewOnce
                      ? ViskaColors.ephemeralOnContainer
                      : ViskaColors.textMuted,
                ),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSendText?.call(),
            ),
          ),
          const SizedBox(width: ViskaSpacing.spaceSm),
          GestureDetector(
            onLongPressStart: (_) => onStartRecording(),
            onLongPressMoveUpdate: (details) {
              onMicDragUpdate(
                details.offsetFromOrigin.dx,
                details.offsetFromOrigin.dy,
              );
            },
            onLongPressEnd: (_) => onMicDragEnd(),
            child: ViskaIconButton(
              tooltip: 'Segure para gravar (↑ trava, ← cancela)',
              icon: Icons.mic_rounded,
              variant: ViskaIconButtonVariant.tonal,
              onPressed: isSendingVoice ? null : onStartRecording,
            ),
          ),
          const SizedBox(width: ViskaSpacing.spaceSm),
          ViskaIconButton(
            icon: Icons.send_rounded,
            variant: ViskaIconButtonVariant.trust,
            onPressed: isSending ? null : onSendText,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return isRecording ? _buildRecordingBar(context) : _buildInputBar(context);
  }
}
