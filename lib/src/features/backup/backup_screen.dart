import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Tela para exportação de backup cifrado com frase mnemônica de 24 palavras (BIP-39).
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.core});

  final Core core;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<String> _words = const [];
  String? _savedFilePath;
  int? _fileSizeBytes;

  @override
  void initState() {
    super.initState();
    _generateBackup();
  }

  Future<void> _generateBackup() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      Directory dir;
      try {
        dir = await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = Directory.current;
      }

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final fileName = 'viska_backup_$timestamp.viskasafe';
      final file = File('${dir.path}/$fileName');

      final mnemonic = await widget.core.exportEncryptedBackup(destPath: file.path);
      final words = mnemonic.trim().split(RegExp(r'\s+'));
      final size = file.existsSync() ? file.lengthSync() : null;

      if (!mounted) return;
      setState(() {
        _words = words;
        _savedFilePath = file.path;
        _fileSizeBytes = size;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Falha ao gerar backup cifrado: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _copyWordsToClipboard() async {
    final text = _words.join(' ');
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('24 palavras copiadas para a área de transferência.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _copyPathToClipboard() async {
    if (_savedFilePath == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: _savedFilePath!));
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Caminho do arquivo copiado para a área de transferência.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exportar Backup Cifrado'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Gerando chaves e contêiner .viskasafe...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _generateBackup,
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar Novamente'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // Banner de segurança e aviso
        Card(
          color: Colors.amber.shade900.withValues(alpha: 0.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.amber.shade700.withValues(alpha: 0.5)),
          ),
          child: const Padding(
            padding: EdgeInsets.all(16.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Anote estas 24 palavras em papel físico seguro. Elas são a única chave '
                    'capaz de descriptografar seu arquivo de backup (.viskasafe). '
                    'Sem a frase mnemônica, ninguém poderá recuperar sua identidade ou contatos.',
                    style: TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'FRASE MNEMÔNICA (24 PALAVRAS)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: DarkTechTheme.textSecondary,
              ),
            ),
            TextButton.icon(
              onPressed: _copyWordsToClipboard,
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar Todas'),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Grid com as 24 palavras numeradas
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 3.2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _words.length,
          itemBuilder: (context, index) {
            final word = _words[index];
            final numStr = (index + 1).toString().padLeft(2, '0');
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: DarkTechTheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: DarkTechTheme.divider.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    numStr,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: DarkTechTheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      word,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 24),

        // Seção do arquivo .viskasafe
        const Text(
          'CONTÊINER CIFRADO (.VISKASAFE)',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: DarkTechTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          color: DarkTechTheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_outline, color: DarkTechTheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Arquivo de backup gerado com sucesso',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (_fileSizeBytes != null)
                            Text(
                              'Tamanho: $_fileSizeBytes bytes (cifrado)',
                              style: const TextStyle(
                                fontSize: 12,
                                color: DarkTechTheme.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_savedFilePath != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: DarkTechTheme.primary, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SelectableText(
                            _savedFilePath!,
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _copyPathToClipboard,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copiar Caminho do Arquivo'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
