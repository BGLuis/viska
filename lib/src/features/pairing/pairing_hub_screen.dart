import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/pairing/pairing_error_copy.dart';
import 'package:viska/src/features/pairing/proximity/proximity_pairing_view.dart';
import 'package:viska/src/features/pairing/screens/pairing_rejected_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';
import 'package:viska/src/rust/ffi/types.dart';
import '../../common_widgets/actions/viska_button.dart';
import '../../common_widgets/feedback/viska_banner.dart';
import '../../common_widgets/inputs/viska_text_field.dart';
import '../../common_widgets/navigation/segmented_tabs.dart';
import '../../common_widgets/security/qr_frame.dart';
import '../../common_widgets/security/scanner_viewfinder.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';

/// Hub de adição de contatos (Telas 12 a 15 do Figma), com três abas:
/// 1. Proximidade: descoberta na LAN e confirmação por código de 6 dígitos.
/// 2. QR Code: "Meu código" e "Escanear".
/// 3. Código: o mesmo payload do QR em texto, para quando a câmera não funciona.
class PairingHubScreen extends StatefulWidget {
  const PairingHubScreen({super.key, required this.core, this.initialTabIndex = 0});

  final Core core;
  final int initialTabIndex;

  @override
  State<PairingHubScreen> createState() => _PairingHubScreenState();
}

class _PairingHubScreenState extends State<PairingHubScreen> {
  static const _tabs = ['Proximidade', 'QR Code', 'Código'];
  static const _qrTabIndex = 1;

  late int _selectedTab = widget.initialTabIndex;

  void _onContactPaired(ContactDto contact) {
    if (!mounted) return;
    Navigator.of(context).pop(contact);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adicionar contato')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
            child: SegmentedTabs(
              tabs: _tabs,
              selectedIndex: _selectedTab,
              onTabSelected: (index) => setState(() => _selectedTab = index),
            ),
          ),
          // Cada aba é recriada ao ser selecionada, para que câmera e descoberta
          // na rede só fiquem ativas enquanto a aba está visível.
          Expanded(
            child: switch (_selectedTab) {
              0 => ProximityPairingView(
                core: widget.core,
                onContactPaired: _onContactPaired,
                onUseQrCode: () => setState(() => _selectedTab = _qrTabIndex),
              ),
              1 => _QrCodeTabView(core: widget.core, onContactPaired: _onContactPaired),
              _ => _ManualCodeTabView(core: widget.core, onContactPaired: _onContactPaired),
            },
          ),
        ],
      ),
    );
  }
}

/// Traduz uma falha de pareamento em mensagem, ou abre a tela própria de
/// chaves divergentes e devolve `null`.
Future<String?> _pairingFailureMessage(BuildContext context, FfiError error) async {
  if (error == FfiError.contactKeyMismatch) {
    await PairingRejectedScreen.show(context);
    return null;
  }
  return pairingErrorMessage(error);
}

/// Aba do QR Code com alternância entre "Meu código" e "Escanear".
class _QrCodeTabView extends StatefulWidget {
  const _QrCodeTabView({required this.core, required this.onContactPaired});

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;

  @override
  State<_QrCodeTabView> createState() => _QrCodeTabViewState();
}

class _QrCodeTabViewState extends State<_QrCodeTabView> {
  bool _isScanning = false;

  bool _processing = false;
  String? _errorMessage;
  PermissionStatus? _cameraPermission;
  bool _isStartingCamera = false;

  /// O scanner entrega o mesmo QR dezenas de vezes por segundo enquanto ele
  /// está na frente da câmera; um código já recusado não é reenviado ao núcleo.
  Uint8List? _lastRejectedPayload;

  late final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    facing: CameraFacing.back,
    autoStart: false,
  );

  late Future<Uint8List> _myPayload = widget.core.myQrPayload();

  @override
  void dispose() {
    try {
      _scannerController.stop().catchError((_) {});
      _scannerController.dispose().catchError((_) {});
    } catch (_) {}
    super.dispose();
  }

  Future<void> _startCamera() async {
    if (_isStartingCamera || !mounted) return;
    _isStartingCamera = true;
    try {
      await _scannerController.start();
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'A câmera não está disponível. Use a aba Código.');
    } finally {
      _isStartingCamera = false;
    }
  }

  Future<void> _requestCameraPermission() async {
    try {
      final status = await LockController.guardTransient(() => Permission.camera.request());
      if (!mounted) return;
      setState(() => _cameraPermission = status);
      if (status.isGranted && _isScanning) {
        await _startCamera();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _cameraPermission = PermissionStatus.denied);
    }
  }

  Future<void> _openSystemSettings() async {
    await LockController.guardTransient(openAppSettings);
    if (!mounted) return;
    await _requestCameraPermission();
  }

  Future<void> _selectView({required bool scanning}) async {
    if (scanning == _isScanning) return;
    setState(() {
      _isScanning = scanning;
      _errorMessage = null;
    });
    if (scanning) {
      // A permissão só é pedida quando o usuário escolhe escanear, não ao abrir a aba.
      if (_cameraPermission?.isGranted == true) {
        await _startCamera();
      } else {
        await _requestCameraPermission();
      }
    } else {
      try {
        await _scannerController.stop();
      } catch (_) {}
    }
  }

  Uint8List? _payloadBytesFrom(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final bytes = switch (barcode.rawDecodedBytes) {
        DecodedBarcodeBytes(:final bytes) => bytes,
        DecodedVisionBarcodeBytes(:final bytes) => bytes,
        null => null,
      };
      if (bytes != null && bytes.length == 145) return bytes;
    }
    return null;
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_processing) return;

    final bytes = _payloadBytesFrom(capture);
    if (bytes == null) return;
    if (_lastRejectedPayload != null && listEquals(bytes, _lastRejectedPayload)) return;

    setState(() {
      _processing = true;
      _errorMessage = null;
    });

    try {
      final contact = await widget.core.pairFromQr(payload: bytes);
      try {
        await _scannerController.stop();
      } catch (_) {}
      if (!mounted) return;
      widget.onContactPaired(contact);
    } on FfiError catch (error) {
      _lastRejectedPayload = bytes;
      if (!mounted) return;
      final message = await _pairingFailureMessage(context, error);
      if (!mounted) return;
      setState(() => _errorMessage = message);
    } catch (_) {
      _lastRejectedPayload = bytes;
      if (!mounted) return;
      setState(() => _errorMessage = 'Erro ao processar o código lido.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ViskaSpacing.spaceLg),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ViskaButton(
                label: 'Meu código',
                icon: Icons.qr_code_2_rounded,
                style: _isScanning ? ViskaButtonStyle.ghost : ViskaButtonStyle.secondary,
                onPressed: () => _selectView(scanning: false),
              ),
              const SizedBox(width: ViskaSpacing.spaceSm),
              ViskaButton(
                label: 'Escanear',
                icon: Icons.qr_code_scanner_rounded,
                style: _isScanning ? ViskaButtonStyle.secondary : ViskaButtonStyle.ghost,
                onPressed: () => _selectView(scanning: true),
              ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ViskaSpacing.spaceLg,
              ViskaSpacing.spaceLg,
              ViskaSpacing.spaceLg,
              0,
            ),
            child: ViskaBanner(tone: ViskaBannerTone.danger, message: _errorMessage!),
          ),
        Expanded(child: _isScanning ? _buildScanner(context) : _buildMyCode(context)),
      ],
    );
  }

  Widget _buildScanner(BuildContext context) {
    final permission = _cameraPermission;
    if (permission == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!permission.isGranted) {
      // Negada em definitivo, o sistema nem mostra mais o pedido: só as
      // configurações do aparelho resolvem.
      final blocked = permission.isPermanentlyDenied || permission.isRestricted;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(ViskaSpacing.space2xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48, color: ViskaColors.textMuted),
              const SizedBox(height: ViskaSpacing.spaceMd),
              Text(
                blocked
                    ? 'O acesso à câmera está bloqueado. Libere nas configurações do aparelho ou use a aba Código.'
                    : 'É preciso permitir o uso da câmera para ler o QR Code.',
                textAlign: TextAlign.center,
                style: ViskaTypography.bodyMedium.copyWith(color: ViskaColors.textSecondary),
              ),
              const SizedBox(height: ViskaSpacing.spaceLg),
              ViskaButton(
                label: blocked ? 'Abrir configurações' : 'Permitir câmera',
                onPressed: blocked ? _openSystemSettings : _requestCameraPermission,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: ViskaRadii.borderLg,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _handleDetection,
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(ViskaSpacing.space2xl),
                      child: Text(
                        'A câmera não está disponível. Use a aba Proximidade ou Código.',
                        textAlign: TextAlign.center,
                        style: ViskaTypography.bodyMedium.copyWith(
                          color: ViskaColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
                const ScannerViewfinder(),
              ],
            ),
          ),
        ),
        const SizedBox(height: ViskaSpacing.spaceLg),
        Text(
          'Aponte para o código na tela da outra pessoa.',
          textAlign: TextAlign.center,
          style: ViskaTypography.bodyMedium.copyWith(color: ViskaColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildMyCode(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: FutureBuilder<Uint8List>(
            future: _myPayload,
            builder: (context, snapshot) {
              // Ao trocar o future, o FutureBuilder mantém o erro anterior
              // enquanto o novo está pendente; só o estado `done` é confiável.
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final payload = snapshot.data;
              if (snapshot.hasError || payload == null) {
                return _MyCodeUnavailable(
                  onRetry: () => setState(() {
                    _myPayload = widget.core.myQrPayload();
                  }),
                );
              }

              return SingleChildScrollView(
                padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
                child: Column(
                  children: [
                    QrFrame(
                      size: 264,
                      child: QrImageView.withQr(
                        qr: QrCode.fromUint8List(
                          data: payload,
                          errorCorrectLevel: QrErrorCorrectLevel.M,
                        ),
                        size: 224,
                      ),
                    ),
                    const SizedBox(height: ViskaSpacing.spaceLg),
                    Text(
                      'Peça para a outra pessoa abrir o Viska e escanear este código. '
                      'Depois, escaneie o dela.',
                      textAlign: TextAlign.center,
                      style: ViskaTypography.bodyMedium.copyWith(color: ViskaColors.textSecondary),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const _InPersonNotice(),
      ],
    );
  }
}

class _MyCodeUnavailable extends StatelessWidget {
  const _MyCodeUnavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ViskaSpacing.space2xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Não foi possível gerar o seu código.',
              textAlign: TextAlign.center,
              style: ViskaTypography.bodyMedium.copyWith(color: ViskaColors.textSecondary),
            ),
            const SizedBox(height: ViskaSpacing.spaceLg),
            ViskaButton(
              label: 'Tentar de novo',
              style: ViskaButtonStyle.secondary,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _InPersonNotice extends StatelessWidget {
  const _InPersonNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.info_outline_rounded, size: 16, color: ViskaColors.textMuted),
          ),
          const SizedBox(width: ViskaSpacing.spaceSm),
          Expanded(
            child: Text(
              'Faça isso pessoalmente. Um código recebido por mensagem ou foto não prova '
              'quem está do outro lado.',
              style: ViskaTypography.bodySmall.copyWith(color: ViskaColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aba "Código" (Tela 14 do Figma): o payload do QR em texto.
///
/// O próprio código só é mostrado, nunca copiado. Copiar convida a mandá-lo por
/// outro app, e um código que chega por mensagem não prova quem está do outro
/// lado: a raiz de confiança do Viska é o encontro presencial.
class _ManualCodeTabView extends StatefulWidget {
  const _ManualCodeTabView({required this.core, required this.onContactPaired});

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;

  @override
  State<_ManualCodeTabView> createState() => _ManualCodeTabViewState();
}

class _ManualCodeTabViewState extends State<_ManualCodeTabView> {
  final _inputController = TextEditingController();
  late Future<String> _myCode = _loadMyCode();
  bool _showingMyCode = false;
  bool _processing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _inputController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<String> _loadMyCode() async => base64Encode(await widget.core.myQrPayload());

  Future<void> _submit() async {
    // Quebras de linha e espaços aparecem quando o código é digitado em partes
    // ou colado de um texto quebrado; nenhum deles faz parte do Base64.
    final cleaned = _inputController.text.replaceAll(RegExp(r'\s'), '');
    if (cleaned.isEmpty || _processing) return;

    setState(() {
      _processing = true;
      _errorMessage = null;
    });

    try {
      final Uint8List bytes;
      try {
        bytes = base64Decode(base64.normalize(cleaned));
      } on FormatException {
        setState(
          () =>
              _errorMessage = 'Código inválido. Confira se ele foi digitado ou colado por inteiro.',
        );
        return;
      }
      final contact = await widget.core.pairFromQr(payload: bytes);
      if (!mounted) return;
      widget.onContactPaired(contact);
    } on FfiError catch (error) {
      if (!mounted) return;
      final message = await _pairingFailureMessage(context, error);
      if (!mounted) return;
      setState(() => _errorMessage = message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Não foi possível adicionar o contato. Tente novamente.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  /// Colar só preenche o campo: o usuário ainda confere antes de adicionar.
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A área de transferência está vazia.')));
      return;
    }
    _inputController.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _inputController.text.trim().isNotEmpty && !_processing;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ViskaSpacing.spaceLg,
        0,
        ViskaSpacing.spaceLg,
        ViskaSpacing.spaceLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                Text(
                  'Para quando a câmera não funciona. Use só com alguém que está ao seu lado.',
                  style: ViskaTypography.bodyMedium.copyWith(color: ViskaColors.textSecondary),
                ),
                const SizedBox(height: ViskaSpacing.spaceLg),
                _buildMyCodeCard(),
                const SizedBox(height: ViskaSpacing.spaceLg),
                ViskaTextField(
                  controller: _inputController,
                  labelText: 'Código da outra pessoa',
                  hintText: 'Cole ou digite o código',
                  helperText: 'O código é conferido e não pode ter sido alterado.',
                  errorText: _errorMessage,
                  maxLines: 3,
                  minLines: 1,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste_rounded),
                    tooltip: 'Colar',
                    onPressed: _pasteFromClipboard,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: ViskaSpacing.spaceLg),
          ViskaButton(
            label: 'Adicionar contato',
            isFullWidth: true,
            isLoading: _processing,
            onPressed: canSubmit ? _submit : null,
          ),
        ],
      ),
    );
  }

  Widget _buildMyCodeCard() {
    return Container(
      padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurface,
        borderRadius: ViskaRadii.borderLg,
        border: Border.all(color: ViskaColors.borderDefault),
      ),
      child: FutureBuilder<String>(
        future: _myCode,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final code = snapshot.data;
          if (snapshot.hasError || code == null) {
            return _MyCodeUnavailable(
              onRetry: () => setState(() {
                _myCode = _loadMyCode();
              }),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SEU CÓDIGO', style: ViskaTypography.labelOverline),
              const SizedBox(height: ViskaSpacing.spaceSm),
              Text(
                code,
                maxLines: _showingMyCode ? null : 1,
                overflow: _showingMyCode ? null : TextOverflow.ellipsis,
                style: ViskaTypography.bodyMedium.copyWith(
                  fontFamily: 'monospace',
                  fontSize: _showingMyCode ? 18 : null,
                  height: _showingMyCode ? 1.5 : null,
                ),
              ),
              const SizedBox(height: ViskaSpacing.spaceMd),
              ViskaButton(
                label: _showingMyCode ? 'Ocultar código' : 'Mostrar para a outra pessoa',
                icon: _showingMyCode ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                style: ViskaButtonStyle.secondary,
                onPressed: () => setState(() => _showingMyCode = !_showingMyCode),
              ),
            ],
          );
        },
      ),
    );
  }
}
