import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/features/chat/chat_screen.dart';
import 'package:viska/src/features/lock/inactivity_detector.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/features/onboarding/profile_setup_dialog.dart';
import 'package:viska/src/features/pairing/pairing_hub_screen.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_qr_dialog.dart';
import 'package:viska/src/features/settings/settings_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/rust/frb_generated.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Barreira defensiva contra exceções assíncronas não capturadas (MethodChannels, Streams, Sockets).
  // Retornar true confirma o tratamento e impede que a máquina virtual encerre o processo do app.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) {
      debugPrint('[Viska CrashBarrier] Erro assíncrono interceptado: $error');
    }
    return true;
  };

  // Intercepta erros de framework do Flutter de forma graciosa sem vazar material de chave.
  FlutterError.onError = (FlutterErrorDetails details) {
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  // Substitui a tela vermelha/amarela padrão do Flutter por um contêiner escuro seguro e contido.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFF0B0F14),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 48, color: Color(0xFFFFB800)),
              const SizedBox(height: 16),
              const Text(
                'Falha temporária de interface',
                style: TextStyle(
                  color: Color(0xFFEDEDED),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                kDebugMode ? details.exceptionAsString() : 'Ocorreu um erro transitório na renderização deste elemento.',
                style: const TextStyle(
                  color: Color(0xFF8B949E),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  };

  await RustLib.init();

  String? profile;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--profile' && i + 1 < args.length) {
      profile = args[i + 1];
      break;
    }
  }
  profile ??= Platform.environment['VISKA_PROFILE'];

  final baseDir = await getApplicationSupportDirectory();
  final appDir = profile != null
      ? Directory('${baseDir.path}/profiles/$profile')
      : baseDir;
  if (!await appDir.exists()) {
    await appDir.create(recursive: true);
  }

  final core = await Core.open(appDir: appDir.path);
  // Um único router para o app inteiro: ele cria (e conecta) um transporte
  // por contato sob demanda — Fase 3, F5.
  final router = P2PTransportRouter(core: core);
  final lockController = LockController(
    core: core,
    appDirPath: appDir.path,
  );

  runApp(MainApp(
    core: core,
    router: router,
    lockController: lockController,
    profileName: profile,
  ));
}

class MainApp extends StatelessWidget {
  const MainApp({
    super.key,
    required this.core,
    required this.router,
    required this.lockController,
    this.profileName,
  });

  final Core core;
  final P2PTransportRouter router;
  final LockController lockController;
  final String? profileName;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: profileName != null ? 'Viska ($profileName)' : 'Viska',
      theme: DarkTechTheme.theme,
      home: AnimatedBuilder(
        animation: Listenable.merge([lockController.isLocked, lockController.isDecoyVault]),
        builder: (context, _) {
          if (lockController.isLocked.value) {
            return InactivityDetector(
              controller: lockController,
              child: LockScreen(controller: lockController),
            );
          }

          final currentCore = lockController.activeCore;
          final currentRouter = currentCore == core ? router : P2PTransportRouter(core: currentCore);

          return InactivityDetector(
            controller: lockController,
            child: PairingHomeScreen(
              key: ValueKey(currentCore),
              core: currentCore,
              router: currentRouter,
              lockController: lockController,
              profileName: profileName,
            ),
          );
        },
      ),
    );
  }
}

/// Tela inicial: lista contatos pareados com apelidos customizáveis,
/// exibe perfil do usuário e centraliza a adição via proximidade, QR Code ou manual.
class PairingHomeScreen extends StatefulWidget {
  const PairingHomeScreen({
    super.key,
    required this.core,
    required this.router,
    required this.lockController,
    this.profileName,
  });

  final Core core;
  final P2PTransportRouter router;
  final LockController lockController;
  final String? profileName;

  @override
  State<PairingHomeScreen> createState() => _PairingHomeScreenState();
}

class _PairingHomeScreenState extends State<PairingHomeScreen> {
  late Future<List<ContactDto>> _contacts = widget.core.listContacts();
  String? _myNickname;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final nick = await widget.core.myNickname();
    if (!mounted) return;
    setState(() => _myNickname = nick);

    // Se for primeira vez (sem apelido configurado), exibe diálogo amigável de onboarding
    if (nick == null || nick.trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final updated = await ProfileSetupDialog.show(
          context,
          core: widget.core,
          isInitialOnboarding: true,
        );
        if (updated != null && mounted) {
          setState(() => _myNickname = updated);
        }
      });
    }
  }

  void _refreshContacts() {
    final next = widget.core.listContacts();
    setState(() {
      _contacts = next;
    });
  }

  Future<void> _editMyNickname() async {
    final updated = await ProfileSetupDialog.show(
      context,
      core: widget.core,
      initialNickname: _myNickname,
      isInitialOnboarding: false,
    );
    if (updated != null && mounted) {
      setState(() => _myNickname = updated);
    }
  }

  Future<void> _editContactNickname(ContactDto contact) async {
    final controller = TextEditingController(text: contact.nickname ?? '');
    final newNick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar apelido'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Apelido do contato',
            hintText: 'Ex: Alice',
          ),
          maxLength: 32,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (newNick != null && newNick.trim().isNotEmpty && mounted) {
      await widget.core.setContactNickname(
        contactDeviceId: contact.deviceId,
        nickname: newNick.trim(),
      );
      _refreshContacts();
    }
  }

  Future<void> _openAddContact() async {
    final contact = await Navigator.of(context).push<ContactDto>(
      MaterialPageRoute(
        builder: (_) => PairingHubScreen(core: widget.core),
      ),
    );
    if (contact == null) return;
    _refreshContacts();
    if (!mounted) return;
    await _showSafetyNumber(contact);
  }

  void _openChat(ContactDto contact) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          core: widget.core,
          router: widget.router,
          contactId: ContactId(contact.deviceId),
          contactLabel: contact.nickname,
        ),
      ),
    );
  }

  bool _isOpeningSafetyNumber = false;

  Future<void> _showSafetyNumber(ContactDto contact) async {
    if (_isOpeningSafetyNumber) return;
    _isOpeningSafetyNumber = true;

    try {
      final safetyNumber = await widget.core.safetyNumber(
        contactDeviceId: contact.deviceId,
      );
      if (!mounted) return;

      await showDialog<bool>(
        context: context,
        builder:
            (_) => SafetyNumberQrDialog(
              contact: contact,
              safetyNumber: safetyNumber,
              core: widget.core,
              onVerified: _refreshContacts,
            ),
      );
      _refreshContacts();
    } catch (e, stack) {
      debugPrint('[PairingHomeScreen] Erro ao carregar Safety Number: $e\n$stack');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('Locked')
                ? 'Aplicativo bloqueado. Desbloqueie para verificar contatos.'
                : 'Não foi possível carregar o número de segurança: $e',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      _isOpeningSafetyNumber = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profileName != null ? 'Viska (${widget.profileName})' : 'Viska'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Configurações de Segurança',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(controller: widget.lockController),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  (_myNickname != null && _myNickname!.trim().isNotEmpty)
                      ? _myNickname!.trim()[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(
                (_myNickname != null && _myNickname!.trim().isNotEmpty)
                    ? _myNickname!
                    : 'Definir seu apelido',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Toque para alterar seu nome compartilhado'),
              trailing: const Icon(Icons.edit_outlined, size: 20),
              onTap: _editMyNickname,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<ContactDto>>(
              future: _contacts,
              builder: (context, snapshot) {
                final contacts = snapshot.data;
                if (contacts == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (contacts.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 64,
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Nenhum contato pareado ainda',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Toque no botão abaixo para adicionar por proximidade, QR Code ou manual.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: contacts.length,
                  separatorBuilder: (context, index) => const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    final nickname = contact.nickname;
                    final hasNickname = nickname != null && nickname.trim().isNotEmpty;
                    final displayName = hasNickname ? nickname.trim() : 'Contato sem apelido';
                    final initial = hasNickname ? displayName[0].toUpperCase() : '#';
                    final shortId = contact.deviceId
                        .take(4)
                        .map((b) => b.toRadixString(16).padLeft(2, '0'))
                        .join();

                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(initial),
                      ),
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              style: TextStyle(
                                fontStyle: hasNickname ? FontStyle.normal : FontStyle.italic,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (contact.isVerified) ...[
                            const SizedBox(width: 6),
                            const Tooltip(
                              message: 'Contato Verificado',
                              child: Icon(
                                Icons.verified,
                                size: 16,
                                color: Color(0xFF00E599),
                                key: Key('verified_badge'),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        'ID: $shortId…',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => _openChat(contact),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Editar apelido',
                            onPressed: () => _editContactNickname(contact),
                          ),
                          IconButton(
                            icon: const Icon(Icons.verified_user_outlined),
                            tooltip: 'Ver número de segurança',
                            onPressed: () => _showSafetyNumber(contact),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_contact',
        onPressed: _openAddContact,
        label: const Text('Adicionar contato'),
        icon: const Icon(Icons.person_add_outlined),
      ),
    );
  }
}
