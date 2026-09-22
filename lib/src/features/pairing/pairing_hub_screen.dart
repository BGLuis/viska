import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:viska/src/features/pairing/pairing_error_copy.dart';
import 'package:viska/src/features/pairing/proximity/proximity_pairing_view.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';
import 'package:viska/src/rust/ffi/types.dart';

/// Hub centralizado de adição de contatos com 3 abas:
/// 1. Proximidade: Descoberta de aparelhos locais na LAN e pareamento presencial com validação SAS.
/// 2. QR Code: Alternância fluida entre "Escanear" e "Meu código".
/// 3. Código Manual: Cópia e colagem de payload em Base64.
class PairingHubScreen extends StatefulWidget {
  const PairingHubScreen({
    super.key,
    required this.core,
    this.initialTabIndex = 0,
  });

  final Core core;
  final int initialTabIndex;

  @override
  State<PairingHubScreen> createState() => _PairingHubScreenState();
}

class _PairingHubScreenState extends State<PairingHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialTabIndex,
  );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _onContactPaired(ContactDto contact) {
    if (!mounted) return;
    Navigator.of(context).pop(contact);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adicionar Contato'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.radar), text: 'Proximidade'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'QR Code'),
            Tab(icon: Icon(Icons.copy_all), text: 'Manual'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          ProximityPairingView(
            core: widget.core,
            onContactPaired: _onContactPaired,
          ),
          _QrCodeTabView(
            core: widget.core,
            onContactPaired: _onContactPaired,
          ),
          _ManualCodeTabView(
            core: widget.core,
            onContactPaired: _onContactPaired,
          ),
        ],
      ),
    );
  }
}

/// Aba do QR Code com alternância entre Escanear e Exibir.
class _QrCodeTabView extends StatefulWidget {
  const _QrCodeTabView({
    required this.core,
    required this.onContactPaired,
  });

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;

  @override
  State<_QrCodeTabView> createState() => _QrCodeTabViewState();
}

class _QrCodeTabViewState extends State<_QrCodeTabView> {
  int _selectedView = 0; // 0 = Escanear, 1 = Meu Código

  bool _hasScanned = false;
  bool _processing = false;
  String? _errorMessage;
  PermissionStatus? _cameraPermission;

  late final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    facing: CameraFacing.back,
  );

  late final Future<Uint8List> _myPayload = widget.core.myQrPayload();

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

    _hasScanned = true;
    setState(() {
      _processing = true;
      _errorMessage = null;
    });

    try {
      final contact = await widget.core.pairFromQr(payload: bytes);
      if (!mounted) return;
      widget.onContactPaired(contact);
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('Escanear amigo'),
                icon: Icon(Icons.camera_alt_outlined),
              ),
              ButtonSegment(
                value: 1,
                label: Text('Meu código'),
                icon: Icon(Icons.qr_code_2_outlined),
              ),
            ],
            selected: {_selectedView},
            onSelectionChanged: (set) => setState(() => _selectedView = set.first),
          ),
        ),
        if (_errorMessage != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        Expanded(
          child: _selectedView == 0
              ? _buildScanner(context)
              : _buildMyCode(context),
        ),
      ],
    );
  }

  Widget _buildScanner(BuildContext context) {
    final permission = _cameraPermission;
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
              const Icon(Icons.camera_alt_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                'É preciso permitir o uso da câmera para ler o QR Code.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _requestCameraPermission,
                child: const Text('Permitir câmera'),
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
          child: Padding(
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
                const SizedBox(height: 12),
                const Text(
                  'Você pode parear pela aba de Proximidade ou Código Manual.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMyCode(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _myPayload,
      builder: (context, snapshot) {
        final payload = snapshot.data;
        if (payload == null) {
          return const Center(child: CircularProgressIndicator());
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: QrImageView.withQr(
                  qr: QrCode.fromUint8List(
                    data: payload,
                    errorCorrectLevel: QrErrorCorrectLevel.M,
                  ),
                  size: 240,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Peça para seu amigo escanear este código com a câmera do app dele.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Aba de pareamento manual (cópia e colagem de Base64).
class _ManualCodeTabView extends StatefulWidget {
  const _ManualCodeTabView({
    required this.core,
    required this.onContactPaired,
  });

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;

  @override
  State<_ManualCodeTabView> createState() => _ManualCodeTabViewState();
}

class _ManualCodeTabViewState extends State<_ManualCodeTabView> {
  final _inputController = TextEditingController();
  bool _processing = false;
  String? _errorMessage;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
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
      widget.onContactPaired(contact);
    } on FfiError catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = pairingErrorMessage(error));
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Código inválido (deve ser Base64 de 145 bytes).');
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
    _inputController.text = text.trim();
    await _pairWithBase64(text);
  }

  Future<void> _copyMyCode() async {
    final payload = await widget.core.myQrPayload();
    final b64 = base64Encode(payload);
    await Clipboard.setData(ClipboardData(text: b64));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Seu código de pareamento foi copiado.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_errorMessage != null) ...[
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(12),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(height: 20),
          ],
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.share_outlined, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Enviar meu código para um amigo',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Você pode copiar seu código em formato texto e enviá-lo por outro canal seguro.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: _copyMyCode,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copiar meu código Base64'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.paste_outlined, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Inserir código recebido',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Cole o código de 145 bytes fornecido pelo seu contato:',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _inputController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Cole o código Base64 aqui...',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste),
                        tooltip: 'Colar da área de transferência',
                        onPressed: _pasteFromClipboard,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _processing
                        ? null
                        : () => _pairWithBase64(_inputController.text),
                    icon: const Icon(Icons.person_add),
                    label: _processing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Parear Contato'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
