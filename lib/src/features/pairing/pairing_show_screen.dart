import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:viska/src/rust/ffi/core.dart';

/// Tela de exibição do próprio QR Code de pareamento.
///
/// O payload são 145 bytes binários — nunca texto. `QrImageView` recebe a
/// versão da matriz travada em 7 e correção de erro M de propósito: o modo
/// alfanumérico (o padrão quando o conteúdo "parece" texto) infla a matriz
/// além do necessário para 145 bytes, que cabem em Versão 7 no modo byte. Ver
/// armadilha 2 do relatório da Fase 2.
class PairingShowScreen extends StatefulWidget {
  const PairingShowScreen({super.key, required this.core});

  final Core core;

  @override
  State<PairingShowScreen> createState() => _PairingShowScreenState();
}

class _PairingShowScreenState extends State<PairingShowScreen> {
  late final Future<Uint8List> _payload = widget.core.myQrPayload();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meu código')),
      body: Center(
        child: FutureBuilder<Uint8List>(
          future: _payload,
          builder: (context, snapshot) {
            final payload = snapshot.data;
            if (payload == null) {
              return const CircularProgressIndicator();
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QrImageView.withQr(
                    qr: QrCode.fromUint8List(
                      data: payload,
                      errorCorrectLevel: QrErrorCorrectLevel.M,
                    ),
                    size: 260,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Peça para a outra pessoa escanear este código com o app dela.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final b64 = base64Encode(payload);
                      await Clipboard.setData(ClipboardData(text: b64));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Código de pareamento copiado.'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copiar código'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
