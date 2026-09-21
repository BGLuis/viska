import 'dart:io';
import 'package:flutter/material.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/security_channel.dart';

/// Tela de configurações de segurança e privacidade (Fase 7, F0/F1/F2/F3/F5).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final LockController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _flagSecureEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadFlagSecure();
  }

  Future<void> _loadFlagSecure() async {
    if (Platform.isAndroid) {
      final enabled = await SecurityChannel.isFlagSecure();
      if (mounted) {
        setState(() => _flagSecureEnabled = enabled);
      }
    }
  }

  Future<void> _toggleFlagSecure(bool enabled) async {
    await SecurityChannel.setFlagSecure(enabled);
    setState(() => _flagSecureEnabled = enabled);
  }

  void _changeAutoLockTimeout(int? seconds) {
    setState(() {
      if (seconds == null || seconds < 0) {
        widget.controller.autoLockTimeout = null;
      } else {
        widget.controller.autoLockTimeout = Duration(seconds: seconds);
      }
    });
  }

  void _showEmergencyEraseDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _EmergencyEraseDialog(controller: widget.controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timeoutSeconds = widget.controller.autoLockTimeout?.inSeconds ?? -1;

    return Scaffold(
      appBar: AppBar(title: const Text('Configurações de Segurança')),
      body: ListView(
        children: [
          const _SectionHeader(title: 'Proteção do Sistema Operacional'),
          if (Platform.isAndroid)
            SwitchListTile(
              title: const Text('Bloquear capturas de tela (FLAG_SECURE)'),
              subtitle: const Text(
                'Impede screenshots, gravação de tela e oculta a janela no alternador de apps.',
              ),
              value: _flagSecureEnabled,
              onChanged: _toggleFlagSecure,
            ),
          const Divider(),
          const _SectionHeader(title: 'Bloqueio do Aplicativo'),
          SwitchListTile(
            title: const Text('Bloquear ao suspender'),
            subtitle: const Text(
              'Destrói chaves e fecha o cofre imediatamente quando o app vai para segundo plano.',
            ),
            value: widget.controller.autoLockOnBackground,
            onChanged: (val) {
              setState(() => widget.controller.autoLockOnBackground = val);
            },
          ),
          ListTile(
            title: const Text('Tempo de inatividade antes de bloquear'),
            subtitle: Text(_formatTimeoutText(timeoutSeconds)),
            trailing: DropdownButton<int>(
              value: timeoutSeconds,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Imediato')),
                DropdownMenuItem(value: 60, child: Text('1 minuto')),
                DropdownMenuItem(value: 300, child: Text('5 minutos')),
                DropdownMenuItem(value: -1, child: Text('Desativado')),
              ],
              onChanged: _changeAutoLockTimeout,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Bloquear agora'),
            subtitle: const Text('Zera as sessões em memória e protege o app'),
            onTap: () {
              Navigator.of(context).pop();
              widget.controller.lock();
            },
          ),
          const Divider(),
          const _SectionHeader(title: 'Zona de Perigo'),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: const Text(
              'Apagamento de emergência',
              style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              'Crypto-shredding irreversível de todas as chaves e banco de dados.',
            ),
            onTap: _showEmergencyEraseDialog,
          ),
        ],
      ),
    );
  }

  String _formatTimeoutText(int seconds) {
    if (seconds == 0) return 'Bloqueia imediatamente';
    if (seconds == 60) return '1 minuto de inatividade';
    if (seconds == 300) return '5 minutos de inatividade';
    return 'Desativado';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
      ),
    );
  }
}

/// Diálogo de confirmação para destruição total e irrevogável de dados (F2).
class _EmergencyEraseDialog extends StatefulWidget {
  const _EmergencyEraseDialog({required this.controller});

  final LockController controller;

  @override
  State<_EmergencyEraseDialog> createState() => _EmergencyEraseDialogState();
}

class _EmergencyEraseDialogState extends State<_EmergencyEraseDialog> {
  static const _requiredConfirmationText = 'DESTRUIR DADOS';
  final _textController = TextEditingController();
  bool _canConfirm = false;
  bool _isErasing = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() {
      final matches = _textController.text.trim() == _requiredConfirmationText;
      if (matches != _canConfirm) {
        setState(() => _canConfirm = matches);
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _executeErase() async {
    setState(() => _isErasing = true);
    await widget.controller.emergencyErase();

    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
          SizedBox(width: 8),
          Expanded(child: Text('Destruição Irreversível')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Esta ação apagará permanentemente a chave mestra no hardware/KeyStore, '
              'o banco de dados local SQLite e todos os arquivos em staging.\n\n'
              'Nenhum dado poderá ser recuperado após este procedimento.',
              style: TextStyle(height: 1.4),
            ),
            const SizedBox(height: 16),
            const Text(
              'Para confirmar, digite exatamente DESTRUIR DADOS abaixo:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: _requiredConfirmationText,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isErasing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
          ),
          onPressed: (_canConfirm && !_isErasing) ? _executeErase : null,
          child: Text(_isErasing ? 'Destruindo...' : 'Destruir Tudo'),
        ),
      ],
    );
  }
}
