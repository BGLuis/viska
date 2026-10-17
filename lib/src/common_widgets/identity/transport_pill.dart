import 'package:flutter/material.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

enum TransportType {
  lan('Wi-Fi local', Icons.wifi_rounded, ViskaColors.trustDefault),
  proximity('Proximidade', Icons.bluetooth_searching_rounded, ViskaColors.trustDefault),
  webrtc('Internet WebRTC', Icons.cloud_done_rounded, ViskaColors.trustDefault),
  offline('Offline', Icons.cloud_off_rounded, ViskaColors.textMuted),
  connecting('Conectando...', Icons.sync_rounded, ViskaColors.ephemeralDefault);

  const TransportType(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

/// Pílula compacta de status de conectividade do canal P2P.
class TransportPill extends StatelessWidget {
  const TransportPill({
    super.key,
    required this.type,
    this.customLabel,
  });

  final TransportType type;
  final String? customLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ViskaSpacing.spaceSm,
        vertical: 2.0,
      ),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurfaceRaised,
        borderRadius: ViskaRadii.borderFull,
        border: Border.all(
          color: type == TransportType.offline ? ViskaColors.borderDefault : type.color.withAlpha(89),
          width: 1.0,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(type.icon, size: 12, color: type.color),
          const SizedBox(width: ViskaSpacing.spaceXs),
          Text(
            customLabel ?? type.label,
            style: ViskaTypography.monoSmall.copyWith(
              fontSize: 10,
              color: type.color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
