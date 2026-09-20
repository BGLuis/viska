import '../p2p_transport.dart';

/// Decide se [LanTransport] deve manter anúncio mDNS ativo para um contato
/// agora — Fase 6, F1, decisão de implementação flagged #4: o beacon é por
/// par, não por aparelho, então anunciar-se para todos os contatos pareados
/// o tempo todo é caro (registro/cancelamento de serviço mDNS por contato).
abstract class LanAdvertisingPolicy {
  bool shouldAdvertise(ContactId contactId);
}

/// Política padrão: sempre anuncia. Nenhuma tela hoje marca uma conversa
/// como "aberta agora" (esse gancho de UI não existe ainda), então usar
/// esta política mantém o comportamento idêntico ao de antes desta classe
/// existir — [LanTransport] só chega a ser criado, de qualquer forma,
/// quando o [P2PTransportRouter] precisa falar com aquele contato
/// especificamente (criação preguiçosa, Fase 3), o que já limita o anúncio
/// simultâneo na prática.
class AlwaysAdvertisePolicy implements LanAdvertisingPolicy {
  const AlwaysAdvertisePolicy();

  @override
  bool shouldAdvertise(ContactId contactId) => true;
}

/// Política real: só anuncia contatos marcados como ativos há no máximo
/// [ttl] — pensada para uma tela de chat chamar [markActive] ao abrir e
/// [markInactive] ao fechar (gancho de UI ainda não ligado a nenhuma tela;
/// esta classe só existe pronta para quando ligarem).
class ActiveContactsAdvertisingPolicy implements LanAdvertisingPolicy {
  ActiveContactsAdvertisingPolicy({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  final Map<ContactId, DateTime> _activeSince = {};

  /// Marca `contactId` como ativo a partir de agora — renova o prazo se já
  /// estava marcado.
  void markActive(ContactId contactId) => _activeSince[contactId] = _now();

  void markInactive(ContactId contactId) => _activeSince.remove(contactId);

  @override
  bool shouldAdvertise(ContactId contactId) {
    final since = _activeSince[contactId];
    if (since == null) return false;
    return _now().difference(since) <= ttl;
  }
}
