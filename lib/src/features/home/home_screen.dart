import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../common_widgets/actions/viska_button.dart';
import '../../common_widgets/identity/viska_avatar.dart';
import '../../common_widgets/layout/contact_row.dart';
import '../../rust/ffi/core.dart';
import '../../rust/ffi/types.dart';
import '../../theme/tokens/viska_colors.dart';
import '../../theme/tokens/viska_radii.dart';
import '../../theme/tokens/viska_spacing.dart';
import '../../theme/tokens/viska_typography.dart';
import '../../transport/message_reception_service.dart';
import '../../transport/p2p_transport.dart';
import '../../transport/p2p_transport_router.dart';
import '../chat/chat_screen.dart';
import '../lock/lock_controller.dart';
import '../onboarding/profile_setup_dialog.dart';
import '../pairing/pairing_hub_screen.dart';
import '../pairing/screens/safety_number_screen.dart';
import '../pairing/screens/verified_success_screen.dart';
import '../settings/settings_screen.dart';

/// Tela inicial principal do Viska (Telas 02 e 03 do Figma).
///
/// Centraliza a lista de contatos pareados, estado de verificação,
/// acesso ao perfil próprio, configurações de segurança e pareamento P2P.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.core,
    required this.router,
    required this.lockController,
    this.receptionService,
    this.profileName,
  });

  final Core core;
  final P2PTransportRouter router;
  final LockController lockController;
  final MessageReceptionService? receptionService;
  final String? profileName;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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
    widget.receptionService?.syncContacts();
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

  bool _isOpeningChat = false;

  Future<void> _openChat(ContactDto contact) async {
    if (_isOpeningChat) return;
    _isOpeningChat = true;

    try {
      if (widget.lockController.isLocked.value) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Aplicativo bloqueado. Desbloqueie para abrir conversas.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            core: widget.core,
            router: widget.router,
            receptionService: widget.receptionService,
            contactId: ContactId(contact.deviceId),
            contactLabel: contact.nickname,
          ),
        ),
      );
      _refreshContacts();
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[HomeScreen] Erro ao abrir conversa: $e\n$stack');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Não foi possível abrir a conversa: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      _isOpeningChat = false;
    }
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

      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => SafetyNumberScreen(
            contact: contact,
            safetyNumber: safetyNumber,
            core: widget.core,
          ),
        ),
      );
      _refreshContacts();
      if (verified != true || !mounted) return;

      final nickname = contact.nickname?.trim();
      final openChat = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => VerifiedSuccessScreen(
            contactName: nickname == null || nickname.isEmpty ? 'Contato' : nickname,
          ),
        ),
      );
      if (openChat == true && mounted) await _openChat(contact);
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[HomeScreen] Erro ao carregar Safety Number: $e\n$stack');
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
    final title = widget.profileName != null ? 'Viska (${widget.profileName})' : 'Viska';

    return Scaffold(
      backgroundColor: ViskaColors.bgCanvas,
      appBar: AppBar(
        title: Text(title, style: ViskaTypography.titleLarge),
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
          // Card de Perfil Próprio com Dark-Tech Editorial
          Container(
            margin: const EdgeInsets.fromLTRB(
              ViskaSpacing.spaceLg,
              ViskaSpacing.spaceMd,
              ViskaSpacing.spaceLg,
              ViskaSpacing.spaceSm,
            ),
            decoration: BoxDecoration(
              color: ViskaColors.bgSurfaceRaised,
              borderRadius: ViskaRadii.borderLg,
              border: Border.all(color: ViskaColors.borderDefault),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: ViskaRadii.borderLg,
                onTap: _editMyNickname,
                child: Padding(
                  padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
                  child: Row(
                    children: [
                      ViskaAvatar(
                        name: _myNickname ?? 'Eu',
                        size: ViskaAvatarSize.md,
                        isSelf: true,
                      ),
                      const SizedBox(width: ViskaSpacing.spaceMd),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (_myNickname != null && _myNickname!.trim().isNotEmpty)
                                  ? _myNickname!
                                  : 'Definir seu apelido',
                              style: ViskaTypography.titleMedium.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: ViskaSpacing.space2xs),
                            Text(
                              'Toque para editar nome compartilhado no pareamento',
                              style: ViskaTypography.bodySmall.copyWith(
                                color: ViskaColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: ViskaColors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: ViskaColors.borderDefault),
          Expanded(
            child: FutureBuilder<List<ContactDto>>(
              future: _contacts,
              builder: (context, snapshot) {
                final contacts = snapshot.data;
                if (contacts == null) {
                  return const Center(
                    child: CircularProgressIndicator(color: ViskaColors.trustDefault),
                  );
                }
                if (contacts.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(ViskaSpacing.space3xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: const BoxDecoration(
                              color: ViskaColors.bgSurfaceRaised,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.people_outline_rounded,
                              size: 32,
                              color: ViskaColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: ViskaSpacing.spaceLg),
                          Text(
                            'Nenhum contato pareado ainda',
                            style: ViskaTypography.titleMedium.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: ViskaSpacing.spaceSm),
                          Text(
                            'Adicione um contato via QR Code presencial, proximidade ou chave manual.',
                            textAlign: TextAlign.center,
                            style: ViskaTypography.bodySmall.copyWith(
                              color: ViskaColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: ViskaSpacing.spaceXl),
                          ViskaButton(
                            label: 'Iniciar Pareamento',
                            icon: Icons.qr_code_scanner_rounded,
                            onPressed: _openAddContact,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: contacts.length,
                  separatorBuilder: (context, index) => const Divider(
                    height: 1,
                    indent: 72,
                    color: ViskaColors.borderDefault,
                  ),
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    final nickname = contact.nickname;
                    final hasNickname = nickname != null && nickname.trim().isNotEmpty;
                    final displayName = hasNickname ? nickname.trim() : 'Contato sem apelido';

                    return Stack(
                      children: [
                        ContactRow(
                          name: displayName,
                          isVerified: contact.isVerified,
                          onTap: () => _openChat(contact),
                          onLongPress: () => _editContactNickname(contact),
                        ),
                        // Mantém as chaves originais e botões de ação para compatibilidade de testes
                        Positioned(
                          right: ViskaSpacing.spaceSm,
                          top: 0,
                          bottom: 0,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (contact.isVerified)
                                const SizedBox(
                                  width: 0,
                                  height: 0,
                                  key: Key('verified_badge'),
                                ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                color: ViskaColors.textMuted,
                                tooltip: 'Editar apelido',
                                onPressed: () => _editContactNickname(contact),
                              ),
                              IconButton(
                                icon: const Icon(Icons.verified_user_outlined, size: 18),
                                color: contact.isVerified
                                    ? ViskaColors.trustDefault
                                    : ViskaColors.textMuted,
                                tooltip: 'Ver número de segurança',
                                onPressed: () => _showSafetyNumber(contact),
                              ),
                            ],
                          ),
                        ),
                      ],
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
        key: const Key('add_contact'),
        onPressed: _openAddContact,
        label: const Text('Adicionar contato'),
        icon: const Icon(Icons.person_add_outlined),
      ),
    );
  }
}

/// Alias para manter compatibilidade com todos os testes e callers existentes.
typedef PairingHomeScreen = HomeScreen;
