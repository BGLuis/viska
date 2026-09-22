import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';
import 'package:viska/src/transport/signaling/proxy_config.dart';

/// Tela de configuração de Proxy de Rede SOCKS5 (Tor) para sinalização.
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key, this.core});

  final Core? core;

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
  bool _enabled = false;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final cfg = ProxyConfigStore.current;
    _enabled = cfg.enabled;
    _hostController = TextEditingController(text: cfg.host);
    _portController = TextEditingController(text: cfg.port.toString());
    _usernameController = TextEditingController(text: cfg.username ?? '');
    _passwordController = TextEditingController(text: cfg.password ?? '');
    _loadFromCore();
  }

  Future<void> _loadFromCore() async {
    final core = widget.core;
    if (core == null) return;
    try {
      final jsonStr = await core.getConfig(key: 'proxy_config');
      if (jsonStr != null && jsonStr.isNotEmpty && mounted) {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        final cfg = ProxyConfig.fromJson(json);
        setState(() {
          _enabled = cfg.enabled;
          _hostController.text = cfg.host;
          _portController.text = cfg.port.toString();
          _usernameController.text = cfg.username ?? '';
          _passwordController.text = cfg.password ?? '';
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _applyOrbotPreset() {
    setState(() {
      _enabled = true;
      _hostController.text = ProxyConfig.orbotDefault.host;
      _portController.text = ProxyConfig.orbotDefault.port.toString();
      _usernameController.clear();
      _passwordController.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Preset Orbot / Tor configurado (127.0.0.1:9050).'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);

    final port = int.tryParse(_portController.text.trim()) ?? 9050;
    final config = ProxyConfig(
      enabled: _enabled,
      host: _hostController.text.trim().isEmpty ? '127.0.0.1' : _hostController.text.trim(),
      port: port,
      username: _usernameController.text.trim().isEmpty ? null : _usernameController.text.trim(),
      password: _passwordController.text.trim().isEmpty ? null : _passwordController.text.trim(),
    );

    // 1. Salva no armazenamento seguro / arquivo local
    await ProxyConfigStore.save(config);

    // 2. Salva no banco de dados SQLite cifrado do Core
    final core = widget.core;
    if (core != null) {
      try {
        await core.setConfig(key: 'proxy_config', value: jsonEncode(config.toJson()));
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Configurações de proxy salvas com sucesso.'),
        backgroundColor: DarkTechTheme.primary,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rede e Proxy SOCKS5 (Tor)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Salvar',
            onPressed: _isSaving ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Banner explicativo sobre privacidade de tráfego
          Card(
            color: DarkTechTheme.surfaceContainer,
            child: const Padding(
              padding: EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, color: DarkTechTheme.primary, size: 28),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'O tráfego de sinalização passa por brokers MQTT públicos. '
                      'Ativar um proxy SOCKS5 (como Orbot) oculta seu endereço IP e impede vazamento de metadados na rede.',
                      style: TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text(
              'Ativar Proxy SOCKS5 para Sinalização',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text('Roteia conexões MQTT pelo túnel proxy'),
            value: _enabled,
            activeThumbColor: DarkTechTheme.primary,
            onChanged: (val) => setState(() => _enabled = val),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _applyOrbotPreset,
            icon: const Icon(Icons.vpn_lock_rounded),
            label: const Text('Configurar para Orbot / Tor Local (127.0.0.1:9050)'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'PARÂMETROS DE CONEXÃO',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: DarkTechTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Host do Proxy',
              hintText: '127.0.0.1',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Porta',
              hintText: '9050',
              prefixIcon: Icon(Icons.tag_rounded),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'AUTENTICAÇÃO (OPCIONAL)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: DarkTechTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: 'Usuário (opcional)',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'Senha (opcional)',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_isSaving ? 'Salvando...' : 'Salvar Preferências de Proxy'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}
