import 'package:flutter/material.dart';
import 'package:viska/src/rust/ffi/core.dart';

/// Diálogo para definição ou alteração do nome/apelido próprio.
class ProfileSetupDialog extends StatefulWidget {
  const ProfileSetupDialog({
    super.key,
    required this.core,
    this.initialNickname,
    this.isInitialOnboarding = false,
  });

  final Core core;
  final String? initialNickname;
  final bool isInitialOnboarding;

  static Future<String?> show(
    BuildContext context, {
    required Core core,
    String? initialNickname,
    bool isInitialOnboarding = false,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: !isInitialOnboarding,
      builder: (context) => ProfileSetupDialog(
        core: core,
        initialNickname: initialNickname,
        isInitialOnboarding: isInitialOnboarding,
      ),
    );
  }

  @override
  State<ProfileSetupDialog> createState() => _ProfileSetupDialogState();
}

class _ProfileSetupDialogState extends State<ProfileSetupDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialNickname ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Informe um nome ou apelido.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.core.setMyNickname(nickname: name);
      if (!mounted) return;
      Navigator.of(context).pop(name);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Erro ao salvar apelido.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.person_pin, size: 40, color: Colors.teal),
      title: Text(
        widget.isInitialOnboarding ? 'Bem-vindo ao Viska' : 'Seu Apelido',
        textAlign: TextAlign.center,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.isInitialOnboarding
                  ? 'Como você gostaria de ser chamado pelos seus amigos nas conversas?'
                  : 'Este nome é compartilhado ao parear e pode ser editado pelo seu contato a qualquer momento.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Seu nome ou apelido',
                hintText: 'Ex.: Carlos, Ana...',
                errorText: _error,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.badge_outlined),
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        if (!widget.isInitialOnboarding)
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Salvar'),
        ),
      ],
    );
  }
}
