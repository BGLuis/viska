import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/inputs/viska_text_field.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_radii.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';
import '../../lock/lock_controller.dart';

/// Tela dedicada para configuração do PIN Normal e PIN de Coação (Tela 22 do Figma / Issue #30).
class DuressPinScreen extends StatefulWidget {
  const DuressPinScreen({
    super.key,
    required this.controller,
    this.onSaved,
  });

  final LockController controller;
  final VoidCallback? onSaved;

  @override
  State<DuressPinScreen> createState() => _DuressPinScreenState();
}

class _DuressPinScreenState extends State<DuressPinScreen> {
  final _normalPinController = TextEditingController();
  final _duressPinController = TextEditingController();
  late int _actionMode = widget.controller.duressActionMode;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _normalPinController.dispose();
    _duressPinController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final normal = _normalPinController.text.trim();
    final duress = _duressPinController.text.trim();

    if (normal.isEmpty && !widget.controller.hasNormalPin) {
      setState(() => _error = 'Configure primeiro o PIN Normal.');
      return;
    }

    if (duress.isNotEmpty && normal.isNotEmpty && duress == normal) {
      setState(() => _error = 'O PIN de Coação não pode ser igual ao PIN Normal.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      if (normal.isNotEmpty) {
        await widget.controller.setNormalPin(normal);
      }
      if (duress.isNotEmpty) {
        await widget.controller.setDuressPin(duress, actionMode: _actionMode);
      }
      if (!mounted) return;
      widget.onSaved?.call();
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Erro ao salvar configurações de PIN.';
      });
    }
  }

  Future<void> _clearPins() async {
    await widget.controller.setNormalPin(null);
    await widget.controller.setDuressPin(null);
    if (!mounted) return;
    widget.onSaved?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(
        title: const Text('PIN e Coação'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ViskaSpacing.space2xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Proteção sob Coação Física',
                style: ViskaTypography.headline,
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                'Defina um PIN secundário de emergência para ser digitado caso você seja obrigado a desbloquear o aparelho sob ameaça.',
                style: ViskaTypography.bodyMedium.copyWith(
                  color: ViskaColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),

              // Alerta sobre Limitações Forenses do Cofre Falso (Issue #30)
              Container(
                padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
                decoration: BoxDecoration(
                  color: ViskaColors.ephemeralContainer,
                  borderRadius: ViskaRadii.borderMd,
                  border: Border.all(color: ViskaColors.ephemeralDefault.withAlpha(89)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 20,
                      color: ViskaColors.ephemeralDefault,
                    ),
                    const SizedBox(width: ViskaSpacing.spaceSm),
                    Expanded(
                      child: Text(
                        'Aviso de Perícia Forense: Em apreensões com cópia física da memória flash (NAND chip-off), peritos avançados podem detectar setores apagados ou divergências temporais.',
                        style: ViskaTypography.bodySmall.copyWith(
                          color: ViskaColors.ephemeralOnContainer,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: ViskaSpacing.space2xl),

              // Campo de PIN Normal
              ViskaTextField(
                controller: _normalPinController,
                labelText: 'PIN Normal de Desbloqueio',
                hintText: widget.controller.hasNormalPin ? '•••• (mantém atual)' : 'Ex: 1234',
                obscureText: true,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),

              // Campo de PIN de Coação
              ViskaTextField(
                controller: _duressPinController,
                labelText: 'PIN de Coação (Duress PIN)',
                hintText: widget.controller.hasDuressPin ? '•••• (mantém atual)' : 'Ex: 9999',
                obscureText: true,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),

              // Seletor de Ação do PIN de Coação
              Text(
                'AÇÃO DO PIN DE COAÇÃO',
                style: ViskaTypography.labelOverline,
              ),
              const SizedBox(height: ViskaSpacing.spaceSm),
              RadioGroup<int>(
                groupValue: _actionMode,
                onChanged: (v) => setState(() => _actionMode = v ?? 0),
                child: Column(
                  children: [
                    RadioListTile<int>(
                      value: 0,
                      fillColor: WidgetStateProperty.all(ViskaColors.trustDefault),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Destruição Silenciosa', style: ViskaTypography.titleMedium),
                      subtitle: Text(
                        'Apaga instantaneamente todas as chaves e encerra o app como se tivesse ocorrido um crash.',
                        style: ViskaTypography.bodySmall.copyWith(color: ViskaColors.textSecondary),
                      ),
                    ),
                    RadioListTile<int>(
                      value: 1,
                      fillColor: WidgetStateProperty.all(ViskaColors.trustDefault),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Cofre Falso (Decoy Vault)', style: ViskaTypography.titleMedium),
                      subtitle: Text(
                        'Abre uma tela inicial vazia simulando uma conta recém-instalada, sem apagar os dados reais.',
                        style: ViskaTypography.bodySmall.copyWith(color: ViskaColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: ViskaSpacing.spaceMd),
                Text(
                  _error!,
                  style: ViskaTypography.bodySmall.copyWith(color: ViskaColors.dangerDefault),
                ),
              ],

              const SizedBox(height: ViskaSpacing.space2xl),
              ViskaButton(
                label: 'SALVAR CONFIGURAÇÃO DE PIN',
                isLoading: _saving,
                isFullWidth: true,
                onPressed: _save,
              ),
              if (widget.controller.hasNormalPin || widget.controller.hasDuressPin) ...[
                const SizedBox(height: ViskaSpacing.spaceMd),
                ViskaButton(
                  label: 'REMOVER PINS CONFIGURADOS',
                  style: ViskaButtonStyle.danger,
                  isFullWidth: true,
                  onPressed: _clearPins,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
