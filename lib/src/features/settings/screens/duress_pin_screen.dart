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
  final _currentPinController = TextEditingController();
  final _normalPinController = TextEditingController();
  final _normalPinConfirmController = TextEditingController();
  final _duressPinController = TextEditingController();
  late int _actionMode = widget.controller.duressActionMode;
  bool _saving = false;
  String? _error;

  LockController get _controller => widget.controller;

  @override
  void dispose() {
    _currentPinController.dispose();
    _normalPinController.dispose();
    _normalPinConfirmController.dispose();
    _duressPinController.dispose();
    super.dispose();
  }

  /// Quem pega o aparelho desbloqueado não pode trocar nem apagar os PINs sem
  /// saber o atual.
  bool _currentPinMatches() {
    if (!_controller.hasNormalPin) return true;
    return _controller.isNormalPin(_currentPinController.text.trim());
  }

  Future<void> _save() async {
    final normal = _normalPinController.text.trim();
    final normalConfirm = _normalPinConfirmController.text.trim();
    final duress = _duressPinController.text.trim();

    if (!_currentPinMatches()) {
      setState(() => _error = 'PIN atual incorreto.');
      return;
    }
    if (normal != normalConfirm) {
      setState(() => _error = 'A confirmação não coincide com o novo PIN Normal.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await _controller.configurePins(
        normalPin: normal.isEmpty ? null : normal,
        duressPin: duress.isEmpty ? null : duress,
        actionMode: _actionMode,
      );
      if (!mounted) return;
      widget.onSaved?.call();
      Navigator.of(context).pop();
    } on PinConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Erro ao salvar configurações de PIN.';
      });
    }
  }

  Future<void> _clearPins() async {
    if (!_currentPinMatches()) {
      setState(() => _error = 'Digite o PIN atual para remover os PINs.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover PINs?'),
        content: const Text(
          'O PIN Normal e o PIN de Coação serão apagados. O app passa a desbloquear só pela autenticação do sistema.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _controller.clearPins();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Erro ao remover os PINs.');
      return;
    }
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

              if (_controller.hasNormalPin) ...[
                ViskaTextField(
                  controller: _currentPinController,
                  labelText: 'PIN atual',
                  hintText: 'Necessário para alterar ou remover',
                  obscureText: true,
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: ViskaSpacing.spaceLg),
              ],

              ViskaTextField(
                controller: _normalPinController,
                labelText: _controller.hasNormalPin ? 'Novo PIN Normal' : 'PIN Normal de Desbloqueio',
                hintText: _controller.hasNormalPin ? 'Deixe vazio para manter o atual' : '4 a 8 dígitos',
                obscureText: true,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              ViskaTextField(
                controller: _normalPinConfirmController,
                labelText: 'Confirme o PIN Normal',
                obscureText: true,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),

              ViskaTextField(
                controller: _duressPinController,
                labelText: 'PIN de Coação (Duress PIN)',
                hintText: _controller.hasDuressPin ? 'Deixe vazio para manter o atual' : 'Mesmo número de dígitos do Normal',
                helperText: 'Precisa ser diferente do PIN Normal e ter o mesmo número de dígitos.',
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
              if (_controller.hasNormalPin || _controller.hasDuressPin) ...[
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
