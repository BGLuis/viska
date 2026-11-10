import 'dart:io';

import 'package:flutter/services.dart';

/// Mantém o processo fora do congelamento de apps em cache do Android enquanto
/// o seletor de arquivos está aberto ou uma transferência está em curso.
///
/// Sem isso o sistema congela o app ao abrir o seletor e derruba os sockets
/// TCP (LAN e WebRTC), e o envio nunca termina. O serviço nativo é do tipo
/// `connectedDevice` e mostra uma notificação genérica, sem contato nem
/// arquivo: ela aparece no log de notificações do sistema.
///
/// No-op fora do Android — o iOS não tem equivalente e o alvo `linux` é só
/// ferramenta de desenvolvimento.
class TransferForegroundService {
  TransferForegroundService({MethodChannel? channel, bool? enabled})
      : _channel = channel ?? const MethodChannel('viska/transfer_service'),
        _enabled = enabled ?? Platform.isAndroid;

  /// Instância única do app: a contagem de usos só vale se o seletor, o envio e
  /// a recepção dividirem o mesmo contador, senão um deles pararia o serviço
  /// debaixo dos outros.
  static final TransferForegroundService shared = TransferForegroundService();

  final MethodChannel _channel;
  final bool _enabled;
  int _leases = 0;
  bool _running = false;

  /// Registra um uso do serviço, iniciando-o no primeiro. Quem chama deve
  /// liberar o [TransferLease] num `finally`.
  ///
  /// Nunca lança: o serviço só melhora a chance de a transferência sobreviver,
  /// e a falha em subi-lo (ex.: o sistema recusa a partir do segundo plano)
  /// deixa o app exatamente como estava antes dele.
  Future<TransferLease> acquire() async {
    _leases++;
    // Tenta subir a cada uso enquanto não subiu: uma recusa do sistema no
    // primeiro uso (segundo plano) não pode condenar os seguintes.
    if (!_running) _running = await _invoke('start');
    return TransferLease._(this);
  }

  Future<void> _release() async {
    if (_leases == 0) return;
    _leases--;
    if (_leases == 0 && _running) {
      _running = false;
      await _invoke('stop');
    }
  }

  /// `true` se o serviço nativo aceitou o comando.
  Future<bool> _invoke(String method) async {
    if (!_enabled) return false;
    try {
      await _channel.invokeMethod<void>(method);
      return true;
    } on PlatformException {
      // Ver doc de [acquire].
    } on MissingPluginException {
      // Ver doc de [acquire].
    }
    return false;
  }
}

/// Uso do [TransferForegroundService]; liberar duas vezes é inofensivo.
class TransferLease {
  TransferLease._(this._service);

  final TransferForegroundService _service;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _service._release();
  }
}
