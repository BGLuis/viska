import 'dart:convert';
import 'dart:io';

/// Configuração de Proxy de Rede (SOCKS5 / Tor) para sinalização.
class ProxyConfig {
  const ProxyConfig({
    this.enabled = false,
    this.host = '127.0.0.1',
    this.port = 9050,
    this.username,
    this.password,
  });

  /// Se o proxy está ativo para sinalização.
  final bool enabled;

  /// Endereço IP ou hostname do servidor SOCKS5 (ex.: 127.0.0.1).
  final String host;

  /// Porta do servidor SOCKS5 (ex.: 9050 para Orbot/Tor local).
  final int port;

  /// Nome de usuário para autenticação SOCKS5 (opcional).
  final String? username;

  /// Senha para autenticação SOCKS5 (opcional).
  final String? password;

  ProxyConfig copyWith({
    bool? enabled,
    String? host,
    int? port,
    String? username,
    String? password,
    bool clearAuth = false,
  }) {
    return ProxyConfig(
      enabled: enabled ?? this.enabled,
      host: host ?? this.host,
      port: port ?? this.port,
      username: clearAuth ? null : (username ?? this.username),
      password: clearAuth ? null : (password ?? this.password),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'port': port,
        if (username != null && username!.isNotEmpty) 'username': username,
        if (password != null && password!.isNotEmpty) 'password': password,
      };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    return ProxyConfig(
      enabled: json['enabled'] as bool? ?? false,
      host: json['host'] as String? ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 9050,
      username: json['username'] as String?,
      password: json['password'] as String?,
    );
  }

  /// Preset padrão para conexão local ao Orbot / Tor.
  static const ProxyConfig orbotDefault = ProxyConfig(
    enabled: true,
    host: '127.0.0.1',
    port: 9050,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyConfig &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          host == other.host &&
          port == other.port &&
          username == other.username &&
          password == other.password;

  @override
  int get hashCode =>
      enabled.hashCode ^
      host.hashCode ^
      port.hashCode ^
      username.hashCode ^
      password.hashCode;
}

/// Armazenamento em memória e disco para preferências de proxy de rede.
class ProxyConfigStore {
  ProxyConfigStore._();

  static ProxyConfig current = const ProxyConfig();
  static String? _storagePath;

  /// Inicializa o caminho do arquivo de persistência de configuração.
  static Future<void> init(String appDirPath) async {
    _storagePath = '$appDirPath/proxy_config.json';
    await load();
  }

  /// Carrega as preferências salvas em disco.
  static Future<ProxyConfig> load() async {
    final path = _storagePath;
    if (path == null) return current;

    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        current = ProxyConfig.fromJson(json);
      }
    } catch (_) {
      // Usa configuração atual se o arquivo estiver corrompido
    }
    return current;
  }

  /// Salva as preferências em disco e atualiza o estado atual.
  static Future<void> save(ProxyConfig config) async {
    current = config;
    final path = _storagePath;
    if (path == null) return;

    try {
      final file = File(path);
      await file.writeAsString(jsonEncode(config.toJson()));
    } catch (_) {
      // Ignora falhas de escrita pontuais
    }
  }
}
