import 'dart:async';

import 'package:flutter/material.dart';
import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/identity/viska_avatar.dart';
import '../../../common_widgets/security/sas_code_widget.dart';
import '../../../rust/ffi/error.dart';
import '../../../rust/ffi/types.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';
import '../pairing_error_copy.dart';
import '../proximity/proximity_pairing_service.dart';
import 'pairing_rejected_screen.dart';

/// Comparação do código de 6 dígitos no pareamento por proximidade (Tela 16 do Figma).
///
/// Devolve o [ContactDto] pelo `Navigator` quando os dois lados confirmam, ou
/// `null` em qualquer outro desfecho. Sair da tela por qualquer caminho, incluindo
/// o voltar do sistema, cancela o pareamento: "São diferentes" é a ação de
/// segurança contra um intermediário na rede local, não uma recusa social.
class SasConfirmationScreen extends StatefulWidget {
  const SasConfirmationScreen({
    super.key,
    required this.peerName,
    required this.sasCode,
    required this.onConfirm,
    required this.onCancel,
    this.whenCancelled,
  });

  final String peerName;
  final String sasCode;
  final Future<ContactDto> Function() onConfirm;
  final VoidCallback onCancel;
  final Future<void>? whenCancelled;

  @override
  State<SasConfirmationScreen> createState() => _SasConfirmationScreenState();
}

class _SasConfirmationScreenState extends State<SasConfirmationScreen> {
  bool _isWaitingRemote = false;

  /// Depois de cancelado pelo outro lado ou de uma falha, a conexão já foi
  /// consumida: confirmar de novo só reenviaria um ACK num socket morto.
  bool _isFinished = false;
  String? _errorMessage;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    widget.whenCancelled?.then((_) {
      if (!mounted || _isFinished) return;
      setState(() {
        _isWaitingRemote = false;
        _isFinished = true;
        _errorMessage = 'Pareamento cancelado pelo outro aparelho.';
      });
      _dismissTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) Navigator.of(context).pop();
      });
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleConfirm() async {
    setState(() {
      _isWaitingRemote = true;
      _errorMessage = null;
    });

    try {
      final contact = await widget.onConfirm();
      if (!mounted) return;
      _isFinished = true;
      Navigator.of(context).pop(contact);
    } on FfiError catch (e) {
      if (!mounted) return;
      if (e == FfiError.contactKeyMismatch) {
        widget.onCancel();
        _isFinished = true;
        unawaited(Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => PairingRejectedScreen(contactName: widget.peerName),
          ),
        ));
        return;
      }
      _fail(pairingErrorMessage(e));
    } on ProximityPairingException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Falha ao concluir o pareamento.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    widget.onCancel();
    setState(() {
      _isWaitingRemote = false;
      _isFinished = true;
      _errorMessage = message;
    });
  }

  void _leave() {
    if (!_isFinished) widget.onCancel();
    _isFinished = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: ViskaColors.bgCanvas,
        appBar: AppBar(
          title: const Text('Confirmar pareamento'),
          leading: BackButton(onPressed: _leave),
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
                        const SizedBox(height: ViskaSpacing.spaceXl),
                        Center(
                          child: ViskaAvatar(name: widget.peerName, size: ViskaAvatarSize.xl),
                        ),
                        const SizedBox(height: ViskaSpacing.spaceLg),
                        Text(
                          widget.peerName,
                          textAlign: TextAlign.center,
                          style: ViskaTypography.headline,
                        ),
                        const SizedBox(height: ViskaSpacing.spaceLg),
                        Text(
                          'O código abaixo precisa ser IGUAL na tela de ${widget.peerName}. '
                          'Comparem lado a lado, em voz alta.',
                          textAlign: TextAlign.center,
                          style: ViskaTypography.bodyMedium.copyWith(
                            color: ViskaColors.textSecondary,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: ViskaSpacing.spaceLg),
                        Center(child: SasCodeWidget(sasCode: widget.sasCode)),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: ViskaSpacing.spaceLg),
                          Text(
                            _errorMessage!,
                            textAlign: TextAlign.center,
                            style: ViskaTypography.bodySmall.copyWith(
                              color: ViskaColors.dangerDefault,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (!_isFinished) ...[
                  ViskaButton(
                    label: _isWaitingRemote
                        ? 'Aguardando ${widget.peerName}...'
                        : 'Os códigos são iguais',
                    isFullWidth: true,
                    onPressed: _isWaitingRemote ? null : _handleConfirm,
                  ),
                  const SizedBox(height: ViskaSpacing.spaceSm),
                ],
                ViskaButton(
                  label: _isFinished ? 'Fechar' : 'São diferentes — cancelar',
                  style: ViskaButtonStyle.ghost,
                  isFullWidth: true,
                  onPressed: _leave,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
