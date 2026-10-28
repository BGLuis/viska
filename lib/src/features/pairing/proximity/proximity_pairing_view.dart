import 'dart:async';

import 'package:flutter/material.dart';
import 'package:viska/src/features/pairing/pairing_error_copy.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/error.dart';
import 'package:viska/src/rust/ffi/types.dart';

import '../../../common_widgets/actions/viska_button.dart';
import '../../../common_widgets/feedback/viska_banner.dart';
import '../../../common_widgets/identity/viska_avatar.dart';
import '../../../theme/tokens/viska_colors.dart';
import '../../../theme/tokens/viska_radii.dart';
import '../../../theme/tokens/viska_spacing.dart';
import '../../../theme/tokens/viska_typography.dart';
import '../screens/pairing_rejected_screen.dart';
import '../screens/sas_confirmation_screen.dart';
import 'proximity_pairing_service.dart';

/// Aba de pareamento por proximidade local (Tela 15 do Figma).
class ProximityPairingView extends StatefulWidget {
  const ProximityPairingView({
    super.key,
    required this.core,
    required this.onContactPaired,
    this.onUseQrCode,
    this.service,
  });

  final Core core;
  final ValueChanged<ContactDto> onContactPaired;

  /// Leva à aba de QR Code, que não depende de comparar dígitos a olho.
  final VoidCallback? onUseQrCode;
  final ProximityPairingService? service;

  @override
  State<ProximityPairingView> createState() => _ProximityPairingViewState();
}

class _ProximityPairingViewState extends State<ProximityPairingView> {
  late final ProximityPairingService _service =
      widget.service ?? ProximityPairingService(core: widget.core);

  StreamSubscription<IncomingProximityPairingRequest>? _incomingSub;
  DiscoveredProximityPeer? _connectingPeer;
  bool _isConfirming = false;
  String? _errorMessage;

  bool get _isBusy => _connectingPeer != null || _isConfirming;

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

      // Um pedido que chega enquanto este aparelho já está conectando com
      // outro abriria duas comparações de código ao mesmo tempo.
      if (_isBusy) {
        request.reject();
        return;
      }

      _isConfirming = true;
      try {
        final contact = await _showSasConfirmation(
          peerName: request.peerName,
          sasCode: request.sasCode,
          onConfirm: request.accept,
          onCancel: request.reject,
          whenCancelled: request.whenCancelled,
        );

        if (contact != null && mounted) {
          widget.onContactPaired(contact);
        }
      } finally {
        _isConfirming = false;
      }
    });
  }

  Future<void> _pairWithPeer(DiscoveredProximityPeer peer) async {
    if (_isBusy) return;

    setState(() {
      _connectingPeer = peer;
      _errorMessage = null;
    });

    try {
      final confirmation = await _service.connectAndPair(peer);
      if (!mounted) {
        confirmation.cancel();
        return;
      }

      _isConfirming = true;
      try {
        final contact = await _showSasConfirmation(
          peerName: confirmation.peerName,
          sasCode: confirmation.sasCode,
          onConfirm: confirmation.confirm,
          onCancel: confirmation.cancel,
          whenCancelled: confirmation.whenCancelled,
        );

        if (contact != null && mounted) {
          widget.onContactPaired(contact);
        }
      } finally {
        _isConfirming = false;
      }
    } on FfiError catch (e) {
      if (!mounted) return;
      if (e == FfiError.contactKeyMismatch) {
        await PairingRejectedScreen.show(context, contactName: _displayName(peer));
        return;
      }
      setState(() => _errorMessage = pairingErrorMessage(e));
    } on ProximityPairingException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Não foi possível conectar ao dispositivo selecionado.');
    } finally {
      if (mounted) setState(() => _connectingPeer = null);
    }
  }

  Future<ContactDto?> _showSasConfirmation({
    required String peerName,
    required String sasCode,
    required Future<ContactDto> Function() onConfirm,
    required void Function() onCancel,
    Future<void>? whenCancelled,
  }) {
    return Navigator.of(context).push<ContactDto>(
      MaterialPageRoute(
        builder: (_) => SasConfirmationScreen(
          peerName: peerName,
          sasCode: sasCode,
          onConfirm: onConfirm,
          onCancel: onCancel,
          whenCancelled: whenCancelled,
        ),
      ),
    );
  }

  static String _displayName(DiscoveredProximityPeer peer) =>
      peer.name.trim().isEmpty ? 'Aparelho sem nome' : peer.name.trim();

  @override
  void dispose() {
    _incomingSub?.cancel();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(ViskaSpacing.spaceLg),
      children: [
        ViskaBanner(
          tone: ViskaBannerTone.trust,
          title: 'Rápido, mas o QR é mais seguro',
          message: 'Aqui a confirmação depende de vocês compararem um código de 6 dígitos. '
              'Se puderem, usem o QR.',
          actionLabel: widget.onUseQrCode == null ? null : 'Usar QR Code',
          onActionPressed: widget.onUseQrCode,
        ),
        const SizedBox(height: ViskaSpacing.spaceLg),
        if (_errorMessage != null) ...[
          ViskaBanner(tone: ViskaBannerTone.danger, message: _errorMessage!),
          const SizedBox(height: ViskaSpacing.spaceLg),
        ],
        Row(
          children: [
            const Icon(Icons.radar, size: 20, color: ViskaColors.trustDefault),
            const SizedBox(width: ViskaSpacing.spaceSm),
            Expanded(
              child: Text(
                'Procurando no mesmo Wi-Fi...',
                style: ViskaTypography.bodyMedium.copyWith(color: ViskaColors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: ViskaSpacing.spaceLg),
        StreamBuilder<List<DiscoveredProximityPeer>>(
          stream: _service.discoveredPeers,
          builder: (context, snapshot) {
            final peers = snapshot.data ?? const <DiscoveredProximityPeer>[];
            if (peers.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: ViskaSpacing.space2xl),
                child: Column(
                  children: [
                    Text(
                      'Nenhum aparelho encontrado por perto',
                      textAlign: TextAlign.center,
                      style: ViskaTypography.titleMedium,
                    ),
                    const SizedBox(height: ViskaSpacing.spaceSm),
                    Text(
                      'A outra pessoa precisa estar no mesmo Wi-Fi, com esta mesma aba aberta.',
                      textAlign: TextAlign.center,
                      style: ViskaTypography.bodySmall.copyWith(color: ViskaColors.textMuted),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                for (final peer in peers) ...[
                  _PeerCard(
                    name: _displayName(peer),
                    isConnecting: _connectingPeer == peer,
                    onConnect: _isBusy ? null : () => _pairWithPeer(peer),
                  ),
                  const SizedBox(height: ViskaSpacing.spaceSm),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard({
    required this.name,
    required this.isConnecting,
    required this.onConnect,
  });

  final String name;
  final bool isConnecting;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(ViskaSpacing.spaceMd),
      decoration: BoxDecoration(
        color: ViskaColors.bgSurface,
        borderRadius: ViskaRadii.borderLg,
        border: Border.all(color: ViskaColors.borderDefault),
      ),
      child: Row(
        children: [
          ViskaAvatar(name: name),
          const SizedBox(width: ViskaSpacing.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ViskaTypography.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'mesmo Wi-Fi',
                  style: ViskaTypography.bodySmall.copyWith(color: ViskaColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: ViskaSpacing.spaceSm),
          ViskaButton(
            label: 'Conectar',
            style: ViskaButtonStyle.secondary,
            isLoading: isConnecting,
            onPressed: onConnect,
          ),
        ],
      ),
    );
  }
}
