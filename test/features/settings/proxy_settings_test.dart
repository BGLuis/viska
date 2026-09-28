import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viska/src/features/settings/proxy_settings_screen.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/transport/signaling/proxy_config.dart';

class _FakeCore implements Core {
  final Map<String, String> configs = {};

  @override
  Future<String?> getConfig({required String key}) async => configs[key];

  @override
  Future<void> setConfig({required String key, required String value}) async {
    configs[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    ProxyConfigStore.current = const ProxyConfig();
  });

  tearDown(() {
    ProxyConfigStore.current = const ProxyConfig();
  });

  group('ProxyConfig Unit Tests', () {
    test('default configuration is disabled with localhost:9050', () {
      const cfg = ProxyConfig();
      expect(cfg.enabled, isFalse);
      expect(cfg.host, '127.0.0.1');
      expect(cfg.port, 9050);
      expect(cfg.username, isNull);
      expect(cfg.password, isNull);
      expect(cfg.disableWebrtc, isFalse);
    });

    test('orbotDefault is enabled on 127.0.0.1:9050', () {
      final cfg = ProxyConfig.orbotDefault;
      expect(cfg.enabled, isTrue);
      expect(cfg.host, '127.0.0.1');
      expect(cfg.port, 9050);
      expect(cfg.disableWebrtc, isFalse);
    });

    test('round-trip JSON serialization preserves all fields', () {
      const original = ProxyConfig(
        enabled: true,
        host: '10.0.0.5',
        port: 1080,
        username: 'alice',
        password: 'secretpassword',
        disableWebrtc: true,
      );

      final json = original.toJson();
      final restored = ProxyConfig.fromJson(json);

      expect(restored.enabled, isTrue);
      expect(restored.host, '10.0.0.5');
      expect(restored.port, 1080);
      expect(restored.username, 'alice');
      expect(restored.password, 'secretpassword');
      expect(restored.disableWebrtc, isTrue);
      expect(restored, equals(original));
    });
  });

  group('ProxySettingsScreen Widget Tests', () {
    testWidgets('renders all fields, verifies banner, and toggles SOCKS5 proxy and disableWebRTC', (tester) async {
      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: ProxySettingsScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rede e Proxy SOCKS5 (Tor)'), findsOneWidget);
      expect(find.text('Ativar Proxy SOCKS5 para Sinalização'), findsOneWidget);

      // Garante que o banner não promete ocultar IP de forma enganosa
      expect(find.textContaining('oculta seu endereço IP'), findsNothing);
      expect(
        find.textContaining('protege só a conexão com o servidor de sinalização'),
        findsOneWidget,
      );

      // Switch principal inicia desativado e o switch de WebRTC não é exibido
      expect(find.byType(Switch), findsOneWidget);
      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.value, isFalse);
      expect(find.text('Desativar WebRTC (Evitar exposição de IP direto)'), findsNothing);

      // Toca no switch principal para ativar proxy
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Agora há dois switches
      expect(find.byType(Switch), findsNWidgets(2));
      final updatedSwitch = tester.widget<Switch>(find.byType(Switch).first);
      expect(updatedSwitch.value, isTrue);
      expect(find.text('Desativar WebRTC (Evitar exposição de IP direto)'), findsOneWidget);

      final webrtcSwitch = tester.widget<Switch>(find.byType(Switch).last);
      expect(webrtcSwitch.value, isFalse);

      // Ativa desativação de WebRTC
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();

      final updatedWebrtcSwitch = tester.widget<Switch>(find.byType(Switch).last);
      expect(updatedWebrtcSwitch.value, isTrue);
    });

    testWidgets('preset button configures Orbot default values', (tester) async {
      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: ProxySettingsScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      // Clica no botão de preset Orbot
      final presetButton = find.text('Configurar para Orbot / Tor Local (127.0.0.1:9050)');
      expect(presetButton, findsOneWidget);
      await tester.tap(presetButton);
      await tester.pumpAndSettle();

      // Verifica campos de host e porta
      final hostField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Host do Proxy'),
      );
      expect(hostField.controller?.text, '127.0.0.1');

      final portField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Porta'),
      );
      expect(portField.controller?.text, '9050');
    });

    testWidgets('saving persists proxy configuration in store and core database', (tester) async {
      tester.view.physicalSize = const Size(2400, 3600);
      addTearDown(tester.view.resetPhysicalSize);

      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: ProxySettingsScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      // Ativa proxy (primeiro switch)
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      // Ativa toggle de desativar WebRTC (segundo switch)
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();

      // Preenche dados customizados
      await tester.enterText(find.widgetWithText(TextField, 'Host do Proxy'), '192.168.1.100');
      await tester.enterText(find.widgetWithText(TextField, 'Porta'), '9150');
      await tester.enterText(find.widgetWithText(TextField, 'Usuário (opcional)'), 'proxyuser');
      await tester.pumpAndSettle();

      // Clica em Salvar
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      // Verifica se salvou na memória / store
      final current = ProxyConfigStore.current;
      expect(current.enabled, isTrue);
      expect(current.disableWebrtc, isTrue);
      expect(current.host, '192.168.1.100');
      expect(current.port, 9150);
      expect(current.username, 'proxyuser');

      // Verifica se salvou no banco SQLite cifrado do Core
      final savedInCore = core.configs['proxy_config'];
      expect(savedInCore, isNotNull);
      final json = jsonDecode(savedInCore!) as Map<String, dynamic>;
      expect(json['enabled'], isTrue);
      expect(json['disableWebrtc'], isTrue);
      expect(json['host'], '192.168.1.100');
      expect(json['port'], 9150);
    });
  });
}


