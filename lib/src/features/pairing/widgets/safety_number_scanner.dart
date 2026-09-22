import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

/// Tela de câmera para leitura e conferência automatizada de Safety Number
/// via QR Code da contraparte.
///
/// Formato esperado: `viska-sn-v1:<deviceIdHex>:<safetyNumberDigits>`
class SafetyNumberScanner extends StatefulWidget {
  const SafetyNumberScanner({
    super.key,
    required this.contact,
    required this.expectedSafetyNumber,
    required this.core,
  });

  final ContactDto contact;
  final SafetyNumberDto expectedSafetyNumber;
  final Core core;

  @override
  State<SafetyNumberScanner> createState() => _SafetyNumberScannerState();
}

class _SafetyNumberScannerState extends State<SafetyNumberScanner> {
  bool _processing = false;
  String? _errorMessage;
  PermissionStatus? _cameraPermission;
  bool _hasScanned = false;

  late final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    facing: CameraFacing.back,
  );

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  @override
  void dispose() {
    try {
      _scannerController.dispose();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _requestCameraPermission() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      setState(() => _cameraPermission = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => _cameraPermission = PermissionStatus.denied);
    }
  }

  String? _extractRawValue(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_hasScanned || _processing) return;

    final rawValue = _extractRawValue(capture);
    if (rawValue == null) return;

    await _processSafetyNumberPayload(rawValue);
  }

  Future<void> _processSafetyNumberPayload(String payload) async {
    final trimmed = payload.trim();
    if (!trimmed.startsWith('viska-sn-v1:')) {
      setState(() => _errorMessage = 'QR Code inválido: formato incompatível.');
      return;
    }

    final parts = trimmed.split(':');
    if (parts.length < 3) {
      setState(() => _errorMessage = 'QR Code incompleto ou malformado.');
      return;
    }

    // Digits extraídos e normalizados sem espaços
    final scannedDigits = parts.sublist(2).join(':').replaceAll(' ', '').trim();
    final expectedDigits = widget.expectedSafetyNumber.digits.replaceAll(' ', '').trim();

    _hasScanned = true;
    setState(() {
      _processing = true;
      _errorMessage = null;
    });

    if (scannedDigits == expectedDigits) {
      // Confrontação bem-sucedida!
      try {
        _scannerController.stop();
      } catch (_) {}
      try {
        await widget.core.verifyContact(
          contactDeviceId: widget.contact.deviceId,
          verified: true,
        );
      } catch (err) {
        if (!mounted) return;
        setState(() {
          _processing = false;
          _hasScanned = false;
          _errorMessage = 'Falha ao persistir status de verificação no banco.';
        });
        return;
      }

      try {
        HapticFeedback.vibrate().catchError((_) {});
      } catch (_) {}

      if (!mounted) return;
      try {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogCtx) => AlertDialog(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified, color: Color(0xFF00E599), size: 26),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Identidade Verificada Criptograficamente!',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Text(
              'O Safety Number de ${widget.contact.nickname ?? 'deste contato'} confere 100% com as chaves criptográficas pós-quânticas autenticadas.',
            ),
            actions: [
              FilledButton(
                key: const Key('verification_dialog_ok_button'),
                onPressed: () => Navigator.of(dialogCtx).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00E599),
                  foregroundColor: Colors.black87,
                ),
                child: const Text('Concluir'),
              ),
            ],
          ),
        );
      } catch (_) {}

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } else {
      // Alerta de Divergência Criptográfica!
      _hasScanned = false;
      setState(() {
        _processing = false;
        _errorMessage =
            '⚠️ Atenção: O Safety Number lido NÃO confere com este contato! As chaves podem ter sido adulteradas.';
      });
      try {
        await HapticFeedback.heavyImpact();
      } catch (_) {}
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A área de transferência está vazia.')),
      );
      return;
    }
    await _processSafetyNumberPayload(text);
  }

  Future<void> _showManualInputDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inserir Payload QR'),
        content: TextField(
          key: const Key('manual_input_field'),
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'viska-sn-v1:<deviceId>:<safetyNumber>',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('manual_input_submit_button'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Verificar'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _processSafetyNumberPayload(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear Safety Number'),
        actions: [
          IconButton(
            key: const Key('paste_payload_button'),
            tooltip: 'Colar do clipboard',
            icon: const Icon(Icons.content_paste),
            onPressed: _processing ? null : _pasteFromClipboard,
          ),
          IconButton(
            key: const Key('manual_payload_button'),
            tooltip: 'Inserir manualmente',
            icon: const Icon(Icons.edit_note),
            onPressed: _processing ? null : _showManualInputDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                _errorMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Expanded(child: _buildScannerView()),
        ],
      ),
    );
  }

  Widget _buildScannerView() {
    final permission = _cameraPermission;

    if (permission == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!permission.isGranted) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt_outlined, size: 56, color: Colors.grey),
              const SizedBox(height: 16),
              const Text(
                'Permissão de câmera necessária para conferência óptica.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _requestCameraPermission,
                child: const Text('Solicitar Permissão'),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste),
                label: const Text('Colar payload do parceiro'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController,
          onDetect: _handleDetection,
          errorBuilder: (context, error) => Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.videocam_off, size: 48, color: Colors.amber),
                  const SizedBox(height: 12),
                  Text('Câmera indisponível (${error.errorCode.name})'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Colar código copiado'),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_processing)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00E599)),
                  SizedBox(height: 16),
                  Text(
                    'Verificando assinatura criptográfica...',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
