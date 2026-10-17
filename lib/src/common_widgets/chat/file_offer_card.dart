import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import '../actions/viska_button.dart';

/// Card de oferta de arquivo pesado (> 100 MB) que exige aceite explícito (Issue #23).
class FileOfferCard extends StatelessWidget {
  const FileOfferCard({
    super.key,
    required this.fileName,
    required this.fileSizeBytes,
    this.onAccept,
    this.onReject,
  });

  final String fileName;
  final int fileSizeBytes;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: ViskaSpacing.spaceLg,
        vertical: ViskaSpacing.spaceSm,
      ),
      padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurfaceRaised,
        borderRadius: ViskaRadii.borderMd,
        border: Border.all(color: ViskaColors.ephemeralDefault.withAlpha(89)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(ViskaSpacing.spaceSm),
                decoration: const BoxDecoration(
                  color: ViskaColors.ephemeralContainer,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.insert_drive_file_outlined,
                  size: 20,
                  color: ViskaColors.ephemeralDefault,
                ),
              ),
              const SizedBox(width: ViskaSpacing.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      fileName,
                      style: ViskaTypography.bodyLarge.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: ViskaSpacing.space2xs),
                    Text(
                      '${_formatSize(fileSizeBytes)} • Oferta de transferência direta',
                      style: ViskaTypography.bodySmall.copyWith(
                        color: ViskaColors.ephemeralOnContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ViskaSpacing.spaceSm),
          Text(
            'Transferências pesadas consomem largura de banda e bateria do seu dispositivo.',
            style: ViskaTypography.bodySmall.copyWith(
              color: ViskaColors.textMuted,
            ),
          ),
          const SizedBox(height: ViskaSpacing.spaceMd),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onReject != null) ...[
                ViskaButton(
                  label: 'Recusar',
                  style: ViskaButtonStyle.ghost,
                  onPressed: onReject,
                ),
                const SizedBox(width: ViskaSpacing.spaceSm),
              ],
              if (onAccept != null)
                ViskaButton(
                  label: 'Aceitar',
                  style: ViskaButtonStyle.primary,
                  icon: Icons.download_rounded,
                  onPressed: onAccept,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
