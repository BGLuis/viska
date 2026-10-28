import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/identity/status_chip.dart';
import '../../../common_widgets/security/safety_number_widget.dart';
import '../../../rust/ffi/core.dart';
import '../../../rust/ffi/types.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';
import '../widgets/safety_number_qr_dialog.dart';
import '../widgets/safety_number_scanner.dart';

/// Comparação do número de segurança (Tela 18 do Figma).
///
/// Devolve `true` pelo `Navigator` quando o contato acaba de ser verificado,
/// por leitura do QR ou pela marcação manual.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({
    super.key,
    required this.contact,
    required this.safetyNumber,
    required this.core,
  });

  final ContactDto contact;
  final SafetyNumberDto safetyNumber;
  final Core core;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  bool _isMarking = false;

  String get _contactName {
    final nickname = widget.contact.nickname?.trim();
    return nickname == null || nickname.isEmpty ? 'contato' : nickname;
  }

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
    if (verified == true && mounted) Navigator.of(context).pop(true);
  }

  /// A leitura do QR exige que a outra pessoa mostre o código dela; este é o
  /// lado que mostra.
  Future<void> _showMyCode() async {
    final verified = await showDialog<bool>(
      context: context,
      builder: (_) => SafetyNumberQrDialog(
        contact: widget.contact,
        safetyNumber: widget.safetyNumber,
        core: widget.core,
      ),
    );
    if (verified == true && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _markManuallyVerified() async {
    if (_isMarking) return;
    setState(() => _isMarking = true);
    try {
      await widget.core.verifyContact(
        contactDeviceId: widget.contact.deviceId,
        verified: true,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isMarking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível marcar o contato como verificado.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVerified = widget.contact.isVerified;

    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(
        title: Text('Verificar $_contactName'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_2_rounded),
            tooltip: 'Mostrar meu código',
            onPressed: _showMyCode,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: isVerified
                            ? const StatusChip(
                                label: 'Verificado',
                                icon: Icons.verified_rounded,
                                tone: StatusChipTone.trust,
                              )
                            : const StatusChip(
                                label: 'Não verificado',
                                icon: Icons.shield_outlined,
                              ),
                      ),
                      const SizedBox(height: ViskaSpacing.spaceLg),
                      Text(
                        'Comparem pessoalmente. Se tudo bater, ninguém está no meio da conversa de vocês.',
                        style: ViskaTypography.bodyMedium.copyWith(
                          color: ViskaColors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: ViskaSpacing.spaceLg),
                      SafetyNumberWidget(
                        digits: widget.safetyNumber.digits,
                        words: widget.safetyNumber.words,
                      ),
                    ],
                  ),
                ),
              ),
              if (!isVerified) ...[
                const SizedBox(height: ViskaSpacing.spaceLg),
                ViskaButton(
                  label: 'Escanear para verificar',
                  icon: Icons.qr_code_scanner_rounded,
                  isFullWidth: true,
                  onPressed: _openScanner,
                ),
                const SizedBox(height: ViskaSpacing.spaceSm),
                ViskaButton(
                  label: 'Os números batem — marcar como verificado',
                  style: ViskaButtonStyle.ghost,
                  isFullWidth: true,
                  isLoading: _isMarking,
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
