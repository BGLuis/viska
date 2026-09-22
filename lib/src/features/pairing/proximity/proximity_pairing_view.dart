import 'dart:async';

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
    this.service,
  });

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;
  final ProximityPairingService? service;

  @override
  State<ProximityPairingView> createState() => _ProximityPairingViewState();
}

class _ProximityPairingViewState extends State<ProximityPairingView>
    with SingleTickerProviderStateMixin {
  late final ProximityPairingService _service =
      widget.service ?? ProximityPairingService(core: widget.core);
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  StreamSubscription<IncomingProximityPairingRequest>? _incomingSub;
  bool _isConnecting = false;
  bool _isDialogOpen = false;
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Não foi possível iniciar a descoberta local.');
    }
  }

  void _listenIncomingRequests() {
    _incomingSub = _service.incomingRequests.listen((request) async {
      if (!mounted) {
        request.reject();
        return;
      }

      if (_isDialogOpen) {
        request.reject();
        return;
      }

      _isDialogOpen = true;
      try {
        final contact = await _showPairingDialog(
          context: context,
          peerName: request.peerName,
          channel: request.channel,
          sasCode: request.sasCode,
          isInitiator: false,
          onConfirm: request.accept,
          onCancel: request.reject,
          whenCancelled: request.whenCancelled,
        );

        if (contact != null && mounted) {
          widget.onContactPaired(contact);
        }
      } finally {
        _isDialogOpen = false;
      }
    });
  }

  Future<void> _pairWithPeer(DiscoveredProximityPeer peer) async {
    if (_isConnecting || _isDialogOpen) return;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final confirmation = await _service.connectAndPair(peer);
      if (!mounted) return;

      _isDialogOpen = true;
      try {
        final contact = await _showPairingDialog(
          context: context,
          peerName: confirmation.peerName,
          channel: confirmation.channel,
          sasCode: confirmation.sasCode,
          isInitiator: true,
          onConfirm: confirmation.confirm,
          onCancel: confirmation.cancel,
          whenCancelled: confirmation.whenCancelled,
        );

        if (contact != null && mounted) {
          widget.onContactPaired(contact);
        }
      } finally {
        _isDialogOpen = false;
      }
    } on FfiError catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = pairingErrorMessage(e));
    } on ProximityPairingException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Não foi possível conectar ao dispositivo selecionado.');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<ContactDto?> _showPairingDialog({
    required BuildContext context,
    required String peerName,
    required int channel,
    required String sasCode,
    required bool isInitiator,
    required Future<ContactDto> Function() onConfirm,
    required void Function() onCancel,
    Future<void>? whenCancelled,
  }) {
    return showDialog<ContactDto>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ProximityPairingDialog(
        peerName: peerName,
        channel: channel,
        sasCode: sasCode,
        isInitiator: isInitiator,
        onConfirm: onConfirm,
        onCancel: onCancel,
        whenCancelled: whenCancelled,
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _incomingSub?.cancel();
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

class _ProximityPairingDialog extends StatefulWidget {
  const _ProximityPairingDialog({
    required this.peerName,
    required this.channel,
    required this.sasCode,
    required this.isInitiator,
    required this.onConfirm,
    required this.onCancel,
    this.whenCancelled,
  });

  final String peerName;
  final int channel;
  final String sasCode;
  final bool isInitiator;
  final Future<ContactDto> Function() onConfirm;
  final void Function() onCancel;
  final Future<void>? whenCancelled;

  @override
  State<_ProximityPairingDialog> createState() => _ProximityPairingDialogState();
}

class _ProximityPairingDialogState extends State<_ProximityPairingDialog> {
  bool _isWaitingRemote = false;
  String? _errorMessage;

  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    widget.whenCancelled?.then((_) {
      if (!mounted) return;
      setState(() {
        _isWaitingRemote = false;
        _errorMessage = 'Pareamento cancelado pelo outro dispositivo.';
      });
      _dismissTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) {
          Navigator.of(context).pop(null);
        }
      });
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleConfirm() async {
    setState(() {
      _isWaitingRemote = true;
      _errorMessage = null;
    });

    try {
      final contact = await widget.onConfirm();
      if (!mounted) return;
      Navigator.of(context).pop(contact);
    } on FfiError catch (e) {
      if (!mounted) return;
      setState(() {
        _isWaitingRemote = false;
        _errorMessage = pairingErrorMessage(e);
      });
    } on ProximityPairingException catch (e) {
      if (!mounted) return;
      setState(() {
        _isWaitingRemote = false;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isWaitingRemote = false;
        _errorMessage = 'Falha ao concluir pareamento.';
      });
    }
  }

  void _handleCancel() {
    widget.onCancel();
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final titleText = widget.isInitiator
        ? 'Conectar com ${widget.peerName}'
        : 'Solicitação de Conexão';

    final contextText = widget.isInitiator
        ? 'Solicitando conexão com ${widget.peerName} (Canal ${widget.channel}).'
        : '${widget.peerName} deseja se conectar com você (Canal ${widget.channel}).';

    final sasDisplay = widget.sasCode.length >= 6
        ? '${widget.sasCode.substring(0, 3)} ${widget.sasCode.substring(3)}'
        : widget.sasCode;

    return AlertDialog(
      icon: Icon(
        widget.isInitiator ? Icons.verified_user_outlined : Icons.security,
        size: 36,
        color: Colors.teal,
      ),
      title: Text(titleText),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            contextText,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 16),
          Text(
            'Confirme se o código abaixo é IDÊNTICO no aparelho de ${widget.peerName}:',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              sasDisplay,
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
            'Confirme verbalmente ou visualmente antes de aceitar.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _handleCancel,
          child: Text(widget.isInitiator ? 'Cancelar' : 'Recusar'),
        ),
        FilledButton(
          onPressed: _isWaitingRemote ? null : _handleConfirm,
          child: _isWaitingRemote
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Aguardando ${widget.peerName}...',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                )
              : const Text('Confirmar Pareamento'),
        ),
      ],
    );
  }
}
