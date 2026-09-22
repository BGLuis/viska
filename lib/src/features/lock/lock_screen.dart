import 'package:flutter/material.dart';
import 'package:viska/src/features/lock/lock_controller.dart';

/// Tela exibida quando o aplicativo está bloqueado (Fase 7, F1 / Fase 9, F3).
///
/// Todas as chaves e sessões em memória foram destruídas no Rust.
/// O usuário pode se autenticar biometricamente ou digitar o PIN (Normal ou Coação).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});

  final LockController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pinController = TextEditingController();
  bool _isAuthenticating = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Dispara a solicitação de autenticação biométrica automaticamente ao exibir a tela
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
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

  Future<void> _submitPin() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) return;

    setState(() {
      _errorMessage = null;
    });

    final success = await widget.controller.verifyAndUnlockWithPin(pin);
    if (!mounted) return;

    if (!success) {
      setState(() {
        _errorMessage = 'PIN incorreto';
      });
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
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
                    color: Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 32),
                // Campo de entrada de PIN numérico
                TextField(
                  controller: _pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  style: const TextStyle(letterSpacing: 8, fontSize: 20, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    counterText: '',
                    hintText: 'Digite o PIN',
                    prefixIcon: Icon(Icons.password_rounded),
                  ),
                  onSubmitted: (_) => _submitPin(),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submitPin,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Entrar com PIN'),
                  ),
                ),
                const SizedBox(height: 16),
                if (_errorMessage != null) ...[
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),
                ],
                OutlinedButton.icon(
                  onPressed: _isAuthenticating ? null : _authenticate,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(_isAuthenticating ? 'Verificando...' : 'Desbloquear'),
                  style: OutlinedButton.styleFrom(
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
