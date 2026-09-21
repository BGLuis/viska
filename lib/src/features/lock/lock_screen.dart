import 'package:flutter/material.dart';
import 'package:viska/src/features/lock/lock_controller.dart';

/// Tela exibida quando o aplicativo está bloqueado (Fase 7, F1).
///
/// Todas as chaves e sessões em memória foram destruídas no Rust.
/// O usuário precisa se autenticar biometricamente para desfraldar o cofre.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});

  final LockController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _isAuthenticating = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Dispara a solicitação de autenticação automaticamente ao exibir a tela
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    if (_isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    final success = await widget.controller.unlock();

    if (!mounted) return;
    setState(() {
      _isAuthenticating = false;
      if (!success) {
        _errorMessage = 'Falha na autenticação ou cofre indisponível.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 72,
                  color: Colors.blueGrey,
                ),
                const SizedBox(height: 24),
                Text(
                  'Viska Bloqueado',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'As chaves de sessão foram destruídas em memória e o banco de dados está fechado.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 36),
                if (_errorMessage != null) ...[
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                  const SizedBox(height: 16),
                ],
                ElevatedButton.icon(
                  onPressed: _isAuthenticating ? null : _authenticate,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(_isAuthenticating ? 'Verificando...' : 'Desbloquear'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
