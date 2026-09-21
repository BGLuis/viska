import 'package:flutter/material.dart';
import 'package:viska/src/features/pairing/pairing_error_copy.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';
import 'package:viska/src/rust/ffi/types.dart';

import 'proximity_pairing_service.dart';

/// Aba de pareamento por proximidade local (LAN / Rádios Locais).
class ProximityPairingView extends StatefulWidget {
  const ProximityPairingView({
    super.key,
    required this.core,
    required this.onContactPaired,
  });

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;

  @override
  State<ProximityPairingView> createState() => _ProximityPairingViewState();
}

class _ProximityPairingViewState extends State<ProximityPairingView>
    with SingleTickerProviderStateMixin {
  late final ProximityPairingService _service = ProximityPairingService(core: widget.core);
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startService();
    _listenIncomingRequests();
  }

  Future<void> _startService() async {
    try {
      await _service.start();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Não foi possível iniciar a descoberta local.');
    }
  }

  void _listenIncomingRequests() {
    _service.incomingRequests.listen((request) async {
      if (!mounted) {
        request.reject();
        return;
      }

      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.security, size: 36, color: Colors.teal),
          title: const Text('Solicitação de Pareamento'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${request.peerName} deseja parear com seu aparelho (Canal ${request.channel}).',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              const Text(
                'Código de Segurança Presencial (SAS):',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${request.sasCode.substring(0, 3)} ${request.sasCode.substring(3)}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 28,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Confirme verbalmente ou visualmente se o número acima é IDÊNTICO no aparelho do seu amigo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Recusar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirmar Código'),
            ),
          ],
        ),
      );

      if (accepted == true) {
        try {
          final contact = await request.accept();
          if (!mounted) return;
          widget.onContactPaired(contact);
        } catch (e) {
          if (!mounted) return;
          setState(() => _errorMessage = 'Erro ao concluir pareamento.');
        }
      } else {
        request.reject();
      }
    });
  }

  Future<void> _pairWithPeer(DiscoveredProximityPeer peer) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final confirmation = await _service.connectAndPair(peer);
      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.verified_user_outlined, size: 36, color: Colors.teal),
          title: Text('Parear com ${peer.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Canal ${peer.channel}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              const Text(
                'Código de Segurança Presencial (SAS):',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${confirmation.sasCode.substring(0, 3)} ${confirmation.sasCode.substring(3)}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 28,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Confirme verbalmente ou visualmente se o número acima é IDÊNTICO no aparelho do seu amigo.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirmar e Adicionar'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        final contact = await confirmation.confirm();
        if (!mounted) return;
        widget.onContactPaired(contact);
      } else {
        confirmation.cancel();
      }
    } on FfiError catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = pairingErrorMessage(e));
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Não foi possível conectar ao dispositivo selecionado.');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_errorMessage != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.teal.withValues(alpha: 0.3 + 0.7 * _pulseController.value),
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),
              const Text(
                'Procurando aparelhos próximos na rede local...',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<List<DiscoveredProximityPeer>>(
            stream: _service.discoveredPeers,
            builder: (context, snapshot) {
              final peers = snapshot.data ?? [];
              if (peers.isEmpty) {
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.radar,
                          size: 64,
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Nenhum aparelho encontrado por perto',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Certifique-se de que o outro aparelho está conectado ao mesmo Wi-Fi ou Roteador e com esta tela de Proximidade aberta.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.separated(
                itemCount: peers.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final peer = peers[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        peer.name.isNotEmpty ? peer.name.substring(0, 1).toUpperCase() : '?',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    title: Text(peer.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Canal ${peer.channel} • ${peer.address.address}'),
                    trailing: _isConnecting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link, color: Colors.teal),
                    onTap: _isConnecting ? null : () => _pairWithPeer(peer),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
