import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/features/chat/chat_screen.dart';
import 'package:viska/src/features/lock/inactivity_detector.dart';
import 'package:viska/src/features/lock/lock_controller.dart';
import 'package:viska/src/features/lock/lock_screen.dart';
import 'package:viska/src/features/pairing/pairing_scan_screen.dart';
import 'package:viska/src/features/pairing/pairing_show_screen.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_view.dart';
import 'package:viska/src/features/settings/settings_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/rust/frb_generated.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
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
      home: ValueListenableBuilder<bool>(
        valueListenable: lockController.isLocked,
        builder: (context, isLocked, _) {
          return InactivityDetector(
            controller: lockController,
            child: isLocked
                ? LockScreen(controller: lockController)
                : PairingHomeScreen(
                    core: core,
                    router: router,
                    lockController: lockController,
                    profileName: profileName,
                  ),
          );
        },
      ),
    );
  }
}

/// Tela inicial mínima: lista contatos já pareados e dá acesso às telas de
/// exibição e leitura do QR Code, além da conversa com cada um.
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

  void _refreshContacts() {
    setState(() => _contacts = widget.core.listContacts());
  }

  Future<void> _openScan() async {
    final contact = await Navigator.of(context).push<ContactDto>(
      MaterialPageRoute(builder: (_) => PairingScanScreen(core: widget.core)),
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

  Future<void> _showSafetyNumber(ContactDto contact) async {
    final safetyNumber = await widget.core.safetyNumber(
      contactDeviceId: contact.deviceId,
    );
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Contato pareado'),
            content: SafetyNumberView(safetyNumber: safetyNumber),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fechar'),
              ),
            ],
          ),
    );
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
      body: FutureBuilder<List<ContactDto>>(
        future: _contacts,
        builder: (context, snapshot) {
          final contacts = snapshot.data;
          if (contacts == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (contacts.isEmpty) {
            return const Center(child: Text('Nenhum contato pareado ainda.'));
          }
          return ListView.builder(
            itemCount: contacts.length,
            itemBuilder: (context, index) {
              final contact = contacts[index];
              return ListTile(
                title: Text(contact.nickname ?? 'Contato sem apelido'),
                onTap: () => _openChat(contact),
                trailing: IconButton(
                  icon: const Icon(Icons.verified_user_outlined),
                  tooltip: 'Ver número de segurança',
                  onPressed: () => _showSafetyNumber(contact),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'show',
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PairingShowScreen(core: widget.core),
                  ),
                ),
            label: const Text('Meu código'),
            icon: const Icon(Icons.qr_code),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'scan',
            onPressed: _openScan,
            label: const Text('Escanear'),
            icon: const Icon(Icons.qr_code_scanner),
          ),
        ],
      ),
    );
  }
}
