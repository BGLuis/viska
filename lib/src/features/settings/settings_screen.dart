import 'dart:io';
import 'package:flutter/material.dart';
import 'package:viska/src/features/backup/backup_screen.dart';
import 'package:viska/src/features/backup/restore_screen.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/security_channel.dart';
import 'package:viska/src/features/settings/proxy_settings_screen.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Tela de configurações de segurança, privacidade, rede e backup.
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

  void _showDuressPinDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => _DuressPinSetupDialog(
        controller: widget.controller,
        onSaved: () => setState(() {}),
      ),
    );
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

    final duressModeText = widget.controller.duressActionMode == 0
        ? 'Destruição Silenciosa'
        : 'Cofre Falso (Decoy Vault)';

    final pinStatusSubtitle = widget.controller.hasDuressPin
        ? 'PIN de Coação ativo ($duressModeText)'
        : widget.controller.hasNormalPin
            ? 'PIN Normal configurado (Sem coação)'
            : 'Nenhum PIN configurado';

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
            leading: const Icon(Icons.pin_outlined),
            title: const Text('PIN de Coação (Defesa Física)'),
            subtitle: Text(pinStatusSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showDuressPinDialog,
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

          const _SectionHeader(title: 'Rede e Anonimato'),
          ListTile(
            leading: const Icon(Icons.vpn_lock_outlined, color: DarkTechTheme.primary),
            title: const Text('Rede e Proxy SOCKS5 (Tor)'),
            subtitle: const Text('Roteamento anônimo para sinalização via Orbot / Tor'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProxySettingsScreen(core: widget.controller.activeCore),
                ),
              );
            },
          ),
          const Divider(),

          const _SectionHeader(title: 'Backup e Restauração Cifrada'),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Exportar Backup Cifrado'),
            subtitle: const Text('Gera contêiner .viskasafe com mnemônico de 24 palavras'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BackupScreen(core: widget.controller.activeCore),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore_outlined),
            title: const Text('Restaurar Backup Cifrado'),
            subtitle: const Text('Recupera identidade e contatos a partir de arquivo e 24 palavras'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RestoreScreen(core: widget.controller.activeCore),
                ),
              );
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

/// Diálogo de configuração de PIN Normal e PIN de Coação (Defesa Física).
class _DuressPinSetupDialog extends StatefulWidget {
  const _DuressPinSetupDialog({
    required this.controller,
    required this.onSaved,
  });

  final LockController controller;
  final VoidCallback onSaved;

  @override
  State<_DuressPinSetupDialog> createState() => _DuressPinSetupDialogState();
}

class _DuressPinSetupDialogState extends State<_DuressPinSetupDialog> {
  final _normalPinController = TextEditingController();
  final _duressPinController = TextEditingController();
  late int _actionMode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _actionMode = widget.controller.duressActionMode;
  }

  @override
  void dispose() {
    _normalPinController.dispose();
    _duressPinController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final normal = _normalPinController.text.trim();
    final duress = _duressPinController.text.trim();

    if (normal.isNotEmpty && normal.length < 4) {
      setState(() => _errorText = 'O PIN Normal deve ter pelo menos 4 dígitos.');
      return;
    }

    if (duress.isNotEmpty && duress.length < 4) {
      setState(() => _errorText = 'O PIN de Coação deve ter pelo menos 4 dígitos.');
      return;
    }

    if (normal.isNotEmpty && duress.isNotEmpty && normal == duress) {
      setState(() => _errorText = 'O PIN de Coação deve ser diferente do PIN Normal.');
      return;
    }

    if (normal.isNotEmpty) {
      await widget.controller.setNormalPin(normal);
    }
    if (duress.isNotEmpty) {
      await widget.controller.setDuressPin(duress, actionMode: _actionMode);
    } else {
      widget.controller.duressActionMode = _actionMode;
    }

    widget.onSaved();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _clearPins() async {
    await widget.controller.setNormalPin(null);
    await widget.controller.setDuressPin(null);
    widget.onSaved();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.shield_outlined, color: DarkTechTheme.primary),
          SizedBox(width: 8),
          Expanded(child: Text('PIN e Defesa Física')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'O PIN de Coação (Duress PIN) é uma salvaguarda para quando você é forçado fisicamente '
              'a desbloquear o aparelho sob ameaça.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _normalPinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: 'Novo PIN Normal (desbloqueio legítimo)',
                hintText: widget.controller.hasNormalPin ? '•••• (mantém atual)' : 'Ex: 1234',
                prefixIcon: const Icon(Icons.pin),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _duressPinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: 'Novo PIN de Coação (Duress PIN)',
                hintText: widget.controller.hasDuressPin ? '•••• (mantém atual)' : 'Ex: 9999',
                prefixIcon: const Icon(Icons.warning_amber_rounded, color: Colors.amber),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'AÇÃO AO DIGITAR O PIN DE COAÇÃO:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: DarkTechTheme.textSecondary,
              ),
            ),
            RadioListTile<int>(
              contentPadding: EdgeInsets.zero,
              title: const Text('Destruição Silenciosa', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Apaga chaves e banco imediatamente e fecha o app simulando encerramento inesperado.',
                style: TextStyle(fontSize: 11),
              ),
              value: 0,
              // ignore: deprecated_member_use
              groupValue: _actionMode,
              // ignore: deprecated_member_use
              onChanged: (val) => setState(() => _actionMode = val ?? 0),
            ),
            RadioListTile<int>(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cofre Falso (Decoy Vault)', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Abre um cofre alternativo com histórico inócuo sem revelar a existência dos dados reais.',
                style: TextStyle(fontSize: 11),
              ),
              value: 1,
              // ignore: deprecated_member_use
              groupValue: _actionMode,
              // ignore: deprecated_member_use
              onChanged: (val) => setState(() => _actionMode = val ?? 1),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorText!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (widget.controller.hasNormalPin || widget.controller.hasDuressPin)
          TextButton(
            onPressed: _clearPins,
            child: const Text('Remover PINs', style: TextStyle(color: Colors.redAccent)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Salvar'),
        ),
      ],
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
