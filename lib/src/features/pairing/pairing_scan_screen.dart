import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';

import 'pairing_error_copy.dart';

/// Tela de leitura e inserção do código de pareamento de um contato.
///
/// Suporta leitura ótica de QR Code via câmera (Android e iOS) e inserção manual
/// via código de texto/Base64 (`docs/protocol.md` §8.3), garantindo o pareamento
/// mesmo em ambientes de desenvolvimento ou situações de câmera indisponível.
class PairingScanScreen extends StatefulWidget {
  const PairingScanScreen({super.key, required this.core});

  final Core core;

  @override
  State<PairingScanScreen> createState() => _PairingScanScreenState();
}

class _PairingScanScreenState extends State<PairingScanScreen> {
  bool _processing = false;
  String? _errorMessage;
  PermissionStatus? _cameraPermission;

  bool _isStartingCamera = false;

  late final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    facing: CameraFacing.back,
    autoStart: false,
  );

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

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
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Câmera indisponível: $e');
    } finally {
      _isStartingCamera = false;
    }
  }

  Future<void> _requestCameraPermission() async {
    try {
      final status = await LockController.guardTransient(
        () => Permission.camera.request(),
      );
      if (!mounted) return;
      setState(() => _cameraPermission = status);
      if (status.isGranted) {
        await _startCamera();
      }
    } catch (_) {
      if (!mounted) return;
      // Em plataformas sem suporte a permissões de câmera (ex.: Linux desktop)
      setState(() => _cameraPermission = PermissionStatus.denied);
    }
  }

  bool _hasScanned = false;

  /// `rawValue` é `String` e não sobrevive a um payload binário de 145 bytes
  /// — nunca usar aqui. `rawDecodedBytes.bytes` preserva os bytes crus como o
  /// scanner os leu. Ver armadilha 1 do relatório da Fase 2.
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
    if (_hasScanned || _processing) return;

    final bytes = _payloadBytesFrom(capture);
    if (bytes == null) return;

    // Trava imediatamente antes de qualquer await para descartar frames seguintes
    _hasScanned = true;
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
      Navigator.of(context).pop(contact);
    } on FfiError catch (error) {
      _hasScanned = false;
      if (!mounted) return;
      setState(() => _errorMessage = pairingErrorMessage(error));
    } catch (_) {
      _hasScanned = false;
      if (!mounted) return;
      setState(() => _errorMessage = 'Erro ao processar o código lido.');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _pairWithBase64(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _processing = true;
      _errorMessage = null;
    });

    try {
      final bytes = base64Decode(trimmed);
      final contact = await widget.core.pairFromQr(payload: bytes);
      if (!mounted) return;
      Navigator.of(context).pop(contact);
    } on FfiError catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = pairingErrorMessage(error));
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Código de pareamento inválido (deve ser Base64 de 145 bytes).');
    } finally {
      if (mounted) setState(() => _processing = false);
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
    await _pairWithBase64(text);
  }

  Future<void> _showManualInputDialog() async {
    final textController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Inserir código de pareamento'),
        content: TextField(
          controller: textController,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Cole o código Base64 aqui...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('Parear'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _pairWithBase64(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permission = _cameraPermission;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Escanear código'),
        actions: [
          IconButton(
            tooltip: 'Colar código',
            icon: const Icon(Icons.content_paste),
            onPressed: _processing ? null : _pasteFromClipboard,
          ),
          IconButton(
            tooltip: 'Digitar manualmente',
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
                ),
              ),
            ),
          Expanded(child: _buildScannerArea(permission)),
        ],
      ),
    );
  }

  Widget _buildScannerArea(PermissionStatus? permission) {
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
              const Text(
                'É preciso permitir o uso da câmera para ler o código óptico.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _requestCameraPermission,
                child: const Text('Permitir câmera'),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              const Text(
                'Ou você pode parear inserindo o código manualmente:',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste),
                label: const Text('Colar código copiado'),
              ),
            ],
          ),
        ),
      );
    }

    return MobileScanner(
      controller: _scannerController,
      onDetect: _handleDetection,
      errorBuilder: (context, error) {
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off, size: 48, color: Colors.amber),
                const SizedBox(height: 12),
                Text(
                  'Câmera não disponível (${error.errorCode.name}).',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Colar código copiado'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _showManualInputDialog,
                  child: const Text('Digitar código manualmente'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
