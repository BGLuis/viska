import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:viska/src/features/chat/chat_screen.dart';
import 'package:viska/src/features/pairing/pairing_scan_screen.dart';
import 'package:viska/src/features/pairing/pairing_show_screen.dart';
import 'package:viska/src/features/pairing/widgets/safety_number_view.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/rust/frb_generated.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final appDir = await getApplicationSupportDirectory();
  final core = await Core.open(appDir: appDir.path);
  // Um único router para o app inteiro: ele cria (e conecta) um transporte
  // por contato sob demanda — Fase 3, F5.
  final router = P2PTransportRouter(core: core);

  runApp(MainApp(core: core, router: router));
}

class MainApp extends StatelessWidget {
  const MainApp({super.key, required this.core, required this.router});

  final Core core;
  final P2PTransportRouter router;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: PairingHomeScreen(core: core, router: router));
  }
}

/// Tela inicial mínima: lista contatos já pareados e dá acesso às telas de
/// exibição e leitura do QR Code, além da conversa com cada um.
class PairingHomeScreen extends StatefulWidget {
  const PairingHomeScreen({super.key, required this.core, required this.router});

  final Core core;
  final P2PTransportRouter router;

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
      appBar: AppBar(title: const Text('Viska')),
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
