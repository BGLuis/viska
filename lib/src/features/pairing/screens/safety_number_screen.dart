import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/security/safety_number_widget.dart';
import '../../../rust/ffi/core.dart';
import '../../../rust/ffi/types.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';
import '../widgets/safety_number_scanner.dart';

/// Tela dedicada para verificação visual ou óptica do Safety Number (Tela 18 do Figma).
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({
    super.key,
    required this.contact,
    required this.safetyNumber,
    required this.core,
    this.onVerified,
  });

  final ContactDto contact;
  final SafetyNumberDto safetyNumber;
  final Core core;
  final VoidCallback? onVerified;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  late bool _isVerified = widget.contact.isVerified;

  Future<void> _openScanner() async {
    final verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SafetyNumberScanner(
          contact: widget.contact,
          expectedSafetyNumber: widget.safetyNumber,
          core: widget.core,
        ),
      ),
    );

    if (verified == true && mounted) {
      setState(() => _isVerified = true);
      widget.onVerified?.call();
    }
  }

  Future<void> _markManuallyVerified() async {
    await widget.core.verifyContact(
      contactDeviceId: widget.contact.deviceId,
      verified: true,
    );
    if (!mounted) return;
    setState(() => _isVerified = true);
    widget.onVerified?.call();
  }

  @override
  Widget build(BuildContext context) {
    final contactName = widget.contact.nickname ?? 'Contato';

    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(
        title: const Text('Número de Segurança'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Verificação com $contactName',
                style: ViskaTypography.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                'Compare os 60 dígitos ou as 6 palavras abaixo para garantir que a criptografia pós-quântica (ML-KEM-768 + X25519) não sofreu adulteração.',
                style: ViskaTypography.bodyMedium.copyWith(
                  color: ViskaColors.textSecondary,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: ViskaSpacing.space2xl),
              SafetyNumberWidget(
                digits: widget.safetyNumber.digits,
                words: widget.safetyNumber.words,
              ),
              const SizedBox(height: ViskaSpacing.space2xl),
              if (_isVerified)
                Container(
                  padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
                  decoration: BoxDecoration(
                    color: ViskaColors.trustContainer,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: ViskaColors.trustBorder),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.verified, color: ViskaColors.trustDefault, size: 20),
                      const SizedBox(width: ViskaSpacing.spaceSm),
                      Text(
                        'Contato Verificado Criptograficamente',
                        style: ViskaTypography.labelLarge.copyWith(
                          color: ViskaColors.trustOnContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                ViskaButton(
                  label: 'ESCANEAR QR CODE DO CONTATO',
                  icon: Icons.qr_code_scanner_rounded,
                  style: ViskaButtonStyle.primary,
                  isFullWidth: true,
                  onPressed: _openScanner,
                ),
                const SizedBox(height: ViskaSpacing.spaceMd),
                ViskaButton(
                  label: 'Marcar como Conferido Manualmente',
                  style: ViskaButtonStyle.secondary,
                  isFullWidth: true,
                  onPressed: _markManuallyVerified,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
