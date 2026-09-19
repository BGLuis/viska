import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';

import 'pairing_error_copy.dart';

/// Tela de leitura do QR Code de um contato.
///
/// Pede permissão de câmera explicitamente (armadilha 5 do relatório: o
/// aparelho de teste desta máquina não tem câmera normal, então este fluxo
/// não pôde ser validado opticamente aqui — só o mapeamento de erro e a
/// integração com `Core.pairFromQr`, via testes que não dependem de câmera).
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

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _cameraPermission = status);
  }

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
      if (bytes != null) return bytes;
    }
    return null;
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_processing) return;

    final bytes = _payloadBytesFrom(capture);
    if (bytes == null) return;

    setState(() {
      _processing = true;
      _errorMessage = null;
    });

    try {
      final contact = await widget.core.pairFromQr(payload: bytes);
      if (!mounted) return;
      Navigator.of(context).pop(contact);
    } on FfiError catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = pairingErrorMessage(error));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permission = _cameraPermission;

    return Scaffold(
      appBar: AppBar(title: const Text('Escanear código')),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'É preciso permitir o uso da câmera para ler o código.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _requestCameraPermission,
                child: const Text('Permitir câmera'),
              ),
            ],
          ),
        ),
      );
    }

    return MobileScanner(onDetect: _handleDetection);
  }
}
