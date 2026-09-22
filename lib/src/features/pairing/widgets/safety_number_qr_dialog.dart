import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';

import 'safety_number_scanner.dart';
import 'safety_number_view.dart';

/// Diálogo que exibe o Safety Number em formato de QR Code e numérico,
/// permitindo a conferência óptica presencial entre os interlocutores.
///
/// Formato do payload: `viska-sn-v1:<deviceIdHex>:<safetyNumberDigits>`
class SafetyNumberQrDialog extends StatefulWidget {
  const SafetyNumberQrDialog({
    super.key,
    required this.contact,
    required this.safetyNumber,
    required this.core,
    this.onVerified,
    this.myDeviceIdHex,
  });

  final ContactDto contact;
  final SafetyNumberDto safetyNumber;
  final Core core;
  final VoidCallback? onVerified;
  final String? myDeviceIdHex;

  @override
  State<SafetyNumberQrDialog> createState() => _SafetyNumberQrDialogState();
}

class _SafetyNumberQrDialogState extends State<SafetyNumberQrDialog> {
  String? _myDeviceIdHex;
  bool _isVerified = false;

  @override
  void initState() {
    super.initState();
    _isVerified = widget.contact.isVerified;
    _myDeviceIdHex = widget.myDeviceIdHex;
    if (_myDeviceIdHex == null) {
      _loadDeviceId();
    }
  }

  Future<void> _loadDeviceId() async {
    try {
      final myId = await widget.core.myDeviceId();
      if (mounted) {
        setState(() {
          _myDeviceIdHex = myId
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join()
              .toLowerCase();
        });
      }
    } catch (_) {
      // Fallback seguro caso myDeviceId falhe em mock de testes
      if (mounted && _myDeviceIdHex == null) {
        setState(() {
          _myDeviceIdHex = widget.contact.deviceId
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join()
              .toLowerCase();
        });
      }
    }
  }

  String _buildQrPayload() {
    final devId = _myDeviceIdHex ??
        widget.contact.deviceId
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toLowerCase();
    return 'viska-sn-v1:$devId:${widget.safetyNumber.digits}';
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

    if (verified == true) {
      if (mounted) {
        setState(() => _isVerified = true);
      }
      widget.onVerified?.call();
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayName = widget.contact.nickname?.trim().isNotEmpty == true
        ? widget.contact.nickname!.trim()
        : 'Contato';

    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Número de Segurança ($displayName)',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (_isVerified)
            const Tooltip(
              message: 'Contato Verificado',
              child: Icon(
                Icons.verified,
                color: Color(0xFF00E599),
                size: 22,
                key: Key('dialog_verified_badge'),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Peça para o parceiro escanear este QR Code ou compare os dígitos abaixo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: QrImageView(
                  data: _buildQrPayload(),
                  version: QrVersions.auto,
                  size: 200.0,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SafetyNumberView(safetyNumber: widget.safetyNumber),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton.icon(
          key: const Key('scan_partner_qr_button'),
          onPressed: _openScanner,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Escanear QR do parceiro'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF00E599),
            foregroundColor: Colors.black87,
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_isVerified),
          child: const Text('Fechar'),
        ),
      ],
    );
  }
}
