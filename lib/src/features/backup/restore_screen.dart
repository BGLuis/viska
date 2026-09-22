import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Tela para restauração de identidade e contatos a partir de contêiner .viskasafe e mnemônico de 24 palavras.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({
    super.key,
    required this.core,
    this.onRestored,
  });

  final Core core;
  final VoidCallback? onRestored;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _mnemonicController = TextEditingController();
  final _filePathController = TextEditingController();
  bool _isRestoring = false;
  List<File> _foundBackupFiles = [];

  @override
  void initState() {
    super.initState();
    _mnemonicController.addListener(() => setState(() {}));
    _findLocalBackups();
  }

  @override
  void dispose() {
    _mnemonicController.dispose();
    _filePathController.dispose();
    super.dispose();
  }

  Future<void> _findLocalBackups() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (dir.existsSync()) {
        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.viskasafe'))
            .toList();
        if (mounted) {
          setState(() {
            _foundBackupFiles = files;
            if (_filePathController.text.isEmpty && files.isNotEmpty) {
              _filePathController.text = files.first.path;
            }
          });
        }
      }
    } catch (_) {}
  }

  List<String> get _parsedWords {
    return _mnemonicController.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
  }

  Future<void> _pasteMnemonic() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && mounted) {
      _mnemonicController.text = data!.text!.trim();
    }
  }

  Future<void> _confirmAndRestore() async {
    final words = _parsedWords;
    if (words.length != 24) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'A frase mnemônica precisa ter exatamente 24 palavras (atualmente: ${words.length}).',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final filePath = _filePathController.text.trim();
    if (filePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe o caminho do arquivo .viskasafe.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Arquivo de backup não encontrado no caminho especificado.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber),
            SizedBox(width: 8),
            Text('Confirmar Restauração'),
          ],
        ),
        content: const Text(
          'Esta operação substituirá sua identidade local e sua lista de contatos '
          'pelos dados contidos no backup restaurado.\n\nDeseja prosseguir?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.amber.shade800),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restaurar Agora'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isRestoring = true);

    try {
      final mnemonic = words.join(' ');

      await widget.core.restoreEncryptedBackup(
        mnemonic: mnemonic,
        srcPath: file.path,
      );

      if (!mounted) return;
      setState(() => _isRestoring = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Backup restaurado com sucesso! Identidade e contatos recuperados.'),
          backgroundColor: DarkTechTheme.primary,
          duration: Duration(seconds: 4),
        ),
      );

      widget.onRestored?.call();
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRestoring = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Falha na restauração: arquivo corrompido ou frase mnemônica inválida. ($e)',
          ),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wordsCount = _parsedWords.length;
    final isWordCountValid = wordsCount == 24;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Restaurar Backup Cifrado'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            color: DarkTechTheme.surfaceContainer,
            child: const Padding(
              padding: EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(Icons.restore_page_outlined, color: DarkTechTheme.primary, size: 28),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Forneça o arquivo .viskasafe e a frase de 24 palavras anotadas durante o backup '
                      'para restaurar sua identidade e contatos.',
                      style: TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Seção da Frase Mnemônica
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
              Text(
                '$wordsCount / 24 palavras',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isWordCountValid ? DarkTechTheme.primary : Colors.amber,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _mnemonicController,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Digite ou cole as 24 palavras separadas por espaço...',
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_outlined),
                tooltip: 'Colar da área de transferência',
                onPressed: _pasteMnemonic,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Seção do arquivo .viskasafe
          const Text(
            'ARQUIVO DE BACKUP (.VISKASAFE)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: DarkTechTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _filePathController,
            decoration: const InputDecoration(
              labelText: 'Caminho do arquivo',
              hintText: '/caminho/para/arquivo.viskasafe',
              prefixIcon: Icon(Icons.attach_file),
            ),
          ),
          if (_foundBackupFiles.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Backups encontrados no aparelho:',
              style: TextStyle(fontSize: 12, color: DarkTechTheme.textSecondary),
            ),
            const SizedBox(height: 6),
            ..._foundBackupFiles.map((file) {
              final name = file.path.split(Platform.pathSeparator).last;
              final isSelected = _filePathController.text == file.path;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: isSelected ? DarkTechTheme.primary : null,
                ),
                title: Text(name, style: const TextStyle(fontSize: 13)),
                onTap: () {
                  setState(() => _filePathController.text = file.path);
                },
              );
            }),
          ],
          const SizedBox(height: 32),

          FilledButton.icon(
            key: const Key('restore_backup_button'),
            onPressed: _isRestoring ? null : _confirmAndRestore,
            icon: _isRestoring
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.settings_backup_restore),
            label: Text(_isRestoring ? 'Restaurando...' : 'Restaurar Identidade e Contatos'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}
