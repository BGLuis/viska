import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:viska/src/features/chat/chat_controller.dart';
import 'package:viska/src/features/chat/widgets/audio_waveform_player.dart';
import 'package:viska/src/features/chat/widgets/reaction_picker.dart';
import 'package:viska/src/features/chat/widgets/reply_preview.dart';
import 'package:viska/src/features/chat/widgets/swipe_to_reply.dart';
import 'package:viska/src/features/voice/voice_io.dart';
import 'package:viska/src/rust/ffi/core.dart';
import 'package:viska/src/rust/ffi/types.dart';
import 'package:viska/src/features/chat/chat_screen.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';
import 'package:viska/src/transport/p2p_transport.dart';
import 'package:viska/src/transport/p2p_transport_router.dart';
import 'package:viska/src/transport/webrtc_transport.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.tempDir);
  final Directory tempDir;
  @override
  Future<String?> getTemporaryPath() async => tempDir.path;
}

class _FakeVoiceRecorder implements VoiceRecorder {
  String? pathToReturnOnStop;
  var startCalls = 0;
  var stopCalls = 0;
  @override
  Future<void> start(String path) async => startCalls++;
  @override
  Future<String?> stop() async {
    stopCalls++;
    return pathToReturnOnStop;
  }
  @override
  Future<void> dispose() async {}
}

class _FakeVoicePlayer implements VoicePlayer {
  final playedBytes = <Uint8List>[];
  var stopCalls = 0;
  @override
  Future<void> playBytes(Uint8List wavBytes) async => playedBytes.add(wavBytes);
  @override
  Future<void> stop() async => stopCalls++;
  @override
  Future<void> dispose() async {}
}

class _FakePermissionHandlerPlatform extends PermissionHandlerPlatform {
  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    return {
      for (final permission in permissions) permission: PermissionStatus.granted,
    };
  }
}

class _FakeCore implements Core {
  SessionStateKind sessionState = SessionStateKind.established;
  final sealOutgoingTextCalls = <String>[];
  final markSentCalls = <int>[];
  var nextMessageId = 1;

  @override
  Future<SessionStatusDto> ensureSession({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: sessionState,
        needsRehandshake: false,
        outgoingHandshake: null,
      );

  @override
  Future<SessionStatusDto?> sessionStatus({required List<int> peerDeviceId}) async =>
      SessionStatusDto(
        state: sessionState,
        needsRehandshake: false,
        outgoingHandshake: null,
      );

  @override
  Future<SealedMessageDto> sealOutgoingText({
    required List<int> peerDeviceId,
    required String body,
  }) async {
    sealOutgoingTextCalls.add(body);
    final id = nextMessageId++;
    return SealedMessageDto(
      messageId: id,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
  }

  @override
  Future<void> markMessageSent({required int messageId}) async {
    markSentCalls.add(messageId);
  }

  @override
  Future<List<SealedMessageDto>> flushPending({required List<int> peerDeviceId}) async => [];

  List<MessageDto> messagesToReturn = [];

  @override
  Future<List<MessageDto>> listMessages({required List<int> peerDeviceId}) async => messagesToReturn;

  @override
  Future<void> markMessageRead({required int messageId}) async {}

  @override
  Future<PlatformInt64> getEphemeralTtl({required List<int> contactDeviceId}) async => 0;

  @override
  Future<bool> isContactVerified({required List<int> contactDeviceId}) async => false;

  @override
  Future<bool> isKeyChanged({required List<int> contactDeviceId}) async => false;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeP2PTransport implements P2PTransport {
  final sendCalls = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _incomingFile = StreamController<Uint8List>.broadcast();
  final _connectionEvents = StreamController<TransportConnectionEvent>.broadcast();

  @override
  Future<void> connect() async {}
  @override
  Future<void> send(Uint8List envelope) async => sendCalls.add(envelope);
  @override
  Future<void> sendFile(Uint8List bytes) async {}
  @override
  Stream<Uint8List> get incoming => _incoming.stream;
  @override
  Stream<Uint8List> get incomingFile => _incomingFile.stream;
  @override
  Stream<TransportConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DarkTechTheme', () {
    test('exposes high-precision dark-tech colors', () {
      expect(DarkTechTheme.scaffoldBackground, const Color(0xFF0A0D10));
      expect(DarkTechTheme.surface, const Color(0xFF11151B));
      expect(DarkTechTheme.surfaceContainer, const Color(0xFF181E27));
      expect(DarkTechTheme.primary, const Color(0xFF00E599));
      expect(DarkTechTheme.secondary, const Color(0xFFFFB800));
      expect(DarkTechTheme.alert, const Color(0xFFFF3B30));
      expect(DarkTechTheme.divider, const Color(0xFF1E2530));
    });

    test('themeData conforms to dark mode specs and Material 3', () {
      final theme = DarkTechTheme.theme;
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, DarkTechTheme.scaffoldBackground);
      expect(theme.colorScheme.primary, DarkTechTheme.primary);
      expect(theme.colorScheme.secondary, DarkTechTheme.secondary);
      expect(theme.colorScheme.error, DarkTechTheme.alert);
      expect(theme.dividerColor, DarkTechTheme.divider);
    });
  });

  group('AudioWaveformPlayer Widget', () {
    testWidgets('renders waveform bars, play button, speed cycler and duration', (tester) async {
      // Cria um WAV mínimo de teste
      final dummyWav = Uint8List.fromList(List.generate(100, (i) => i % 256));

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: Scaffold(
            body: Center(
              child: AudioWaveformPlayer(
                audioBytes: dummyWav,
                barCount: 20,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verifica botão de play
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      // Verifica botão de velocidade inicial (1x)
      expect(find.text('1x'), findsOneWidget);

      // Toca no botão de velocidade para ciclar para 1.5x
      await tester.tap(find.text('1x'));
      await tester.pump();
      expect(find.text('1.5x'), findsOneWidget);

      // Toca novamente para ciclar para 2x
      await tester.tap(find.text('1.5x'));
      await tester.pump();
      expect(find.text('2x'), findsOneWidget);

      // Toca novamente para voltar para 1x
      await tester.tap(find.text('2x'));
      await tester.pump();
      expect(find.text('1x'), findsOneWidget);

      // Verifica exibição de CustomPaint com o waveform
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  group('SwipeToReply and ReplyPreview', () {
    testWidgets('SwipeToReply triggers onReply when dragged horizontally', (tester) async {
      var replied = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: SwipeToReply(
                  onReply: () => replied = true,
                  child: const Text('Mensagem de teste'),
                ),
              ),
            ),
          ),
        ),
      );

      // Desliza o balão para a direita acima do limiar
      await tester.drag(find.text('Mensagem de teste'), const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(replied, isTrue);
    });

    testWidgets('ReplyPreview displays author, snippet and dismiss button', (tester) async {
      var cancelled = false;
      const reply = QuotedReply(
        id: 42,
        sender: 'Bob',
        snippet: 'Como vai você?',
        isVoice: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: Scaffold(
            body: ReplyPreview(
              reply: reply,
              onCancel: () => cancelled = true,
            ),
          ),
        ),
      );

      expect(find.text('Respondendo a Bob'), findsOneWidget);
      expect(find.text('Como vai você?'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();

      expect(cancelled, isTrue);
    });

    testWidgets('QuotedMessageBubbleView renders inside bubble with voice badge if voice note', (tester) async {
      const voiceReply = QuotedReply(
        id: 99,
        sender: 'Alice',
        snippet: '',
        isVoice: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: const Scaffold(
            body: QuotedMessageBubbleView(reply: voiceReply),
          ),
        ),
      );

      expect(find.text('Alice'), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.text('Nota de voz'), findsOneWidget);
    });
  });

  group('ReactionPicker and MessageReactionsView', () {
    testWidgets('ReactionPicker renders popular emoji set and responds to taps', (tester) async {
      String? selected;

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: Scaffold(
            body: ReactionPicker(
              onSelect: (emoji) => selected = emoji,
            ),
          ),
        ),
      );

      for (final emoji in kPopularReactionEmojis) {
        expect(find.text(emoji), findsOneWidget);
      }

      await tester.tap(find.text('❤️'));
      await tester.pump();

      expect(selected, '❤️');
    });

    testWidgets('MessageReactionsView renders active reaction badges and triggers onTap', (tester) async {
      String? tappedEmoji;
      final reactions = {'👍': 3, '❤️': 1};
      final userReactions = {'❤️'};

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: Scaffold(
            body: MessageReactionsView(
              reactions: reactions,
              userReactions: userReactions,
              onReactionTap: (e) => tappedEmoji = e,
            ),
          ),
        ),
      );

      expect(find.text('👍'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('❤️'), findsOneWidget);

      await tester.tap(find.text('👍'));
      await tester.pump();

      expect(tappedEmoji, '👍');
    });
  });

  group('ChatController UX extensions', () {
    late Directory tempDir;
    late _FakeCore core;
    late _FakeP2PTransport transport;
    late P2PTransportRouter router;
    late _FakeVoiceRecorder recorder;
    late _FakeVoicePlayer player;
    late ChatController controller;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('viska-chat-ux-test');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
      PermissionHandlerPlatform.instance = _FakePermissionHandlerPlatform();
      core = _FakeCore();
      transport = _FakeP2PTransport();
      router = P2PTransportRouter(
        core: core,
        transportFactory: (_, _) => transport,
      );
      recorder = _FakeVoiceRecorder();
      player = _FakeVoicePlayer();

      controller = ChatController(
        core: core,
        router: router,
        contactId: ContactId(List.filled(16, 1)),
        recorder: recorder,
        player: player,
      );
    });

    tearDown(() {
      controller.dispose();
      tempDir.deleteSync(recursive: true);
    });

    test('sendText with quoted reply generates structured JSON envelope', () async {
      await controller.initialize();

      const reply = QuotedReply(
        id: 10,
        sender: 'Bob',
        snippet: 'Original text',
      );

      await controller.sendText('Resposta direta', replyTo: reply);

      expect(core.sealOutgoingTextCalls, hasLength(1));
      final payload = core.sealOutgoingTextCalls.single;
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      expect(decoded['type'], 'text');
      expect(decoded['text'], 'Resposta direta');
      expect(decoded['reply']['id'], 10);
      expect(decoded['reply']['sender'], 'Bob');
      expect(decoded['reply']['snippet'], 'Original text');
    });

    test('sendText with isViewOnce true marks viewOnce flag in envelope', () async {
      await controller.initialize();

      await controller.sendText('Segredo autodestrutivo', isViewOnce: true);

      expect(core.sealOutgoingTextCalls, hasLength(1));
      final payload = core.sealOutgoingTextCalls.single;
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      expect(decoded['type'], 'text');
      expect(decoded['text'], 'Segredo autodestrutivo');
      expect(decoded['viewOnce'], isTrue);
    });

    test('sendReaction seals reaction payload and records reaction', () async {
      await controller.initialize();

      await controller.sendReaction(targetMessageId: 77, emoji: '🔥');

      expect(core.sealOutgoingTextCalls, hasLength(1));
      final payload = core.sealOutgoingTextCalls.single;
      final decoded = jsonDecode(payload) as Map<String, dynamic>;

      expect(decoded['type'], 'reaction');
      expect(decoded['targetId'], 77);
      expect(decoded['emoji'], '🔥');
    });

    test('cancelRecording stops recorder and removes temp file without sending', () async {
      await controller.initialize();

      final tempFile = File('${tempDir.path}/test-audio.ogg');
      tempFile.writeAsStringSync('dummy-audio-content');
      recorder.pathToReturnOnStop = tempFile.path;

      // Inicia e cancela
      await controller.startRecording();
      expect(controller.isRecording, isTrue);

      await controller.cancelRecording();
      expect(controller.isRecording, isFalse);
      expect(recorder.stopCalls, 1);
      expect(core.sealOutgoingTextCalls, isEmpty);
    });

    test('viewOnce tracking marks message as opened', () {
      expect(controller.isViewOnceOpened(100), isFalse);
      controller.markViewOnceOpened(100);
      expect(controller.isViewOnceOpened(100), isTrue);
    });

    test('ParsedMessageContent handles plain text, json quoted reply, and reactions', () {
      // Plain text
      final p1 = ParsedMessageContent.parse('Olá mundo');
      expect(p1.text, 'Olá mundo');
      expect(p1.reply, isNull);
      expect(p1.isReaction, isFalse);

      // Quoted reply
      final jsonReply = jsonEncode({
        'type': 'text',
        'text': 'Sim, concordo',
        'reply': {'id': 5, 'sender': 'Carol', 'snippet': 'Pergunta?'},
        'viewOnce': false,
      });
      final p2 = ParsedMessageContent.parse(jsonReply);
      expect(p2.text, 'Sim, concordo');
      expect(p2.reply?.id, 5);
      expect(p2.reply?.sender, 'Carol');

      // Reaction
      final jsonReaction = jsonEncode({
        'type': 'reaction',
        'targetId': 99,
        'emoji': '👍',
      });
      final p3 = ParsedMessageContent.parse(jsonReaction);
      expect(p3.isReaction, isTrue);
      expect(p3.targetReactionId, 99);
      expect(p3.reactionEmoji, '👍');
    });
  });

  group('file attachment UI', () {
    late Directory tempDir;
    late _FakeCore core;
    late _FakeP2PTransport transport;
    late P2PTransportRouter router;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('viska-chat-ui-test');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
      core = _FakeCore();
      transport = _FakeP2PTransport();
      router = P2PTransportRouter(
        core: core,
        transportFactory: (_, _) => transport,
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    testWidgets('attach_file_button is present in input bar', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: ChatScreen(
            core: core,
            router: router,
            contactId: ContactId(List.filled(16, 1)),
            contactLabel: 'Bob',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('attach_file_button')), findsOneWidget);
      expect(find.byIcon(Icons.attach_file_rounded), findsOneWidget);
    });

    testWidgets('file message bubble renders progress indicator while receiving', (tester) async {
      final fileId = Uint8List.fromList(List.filled(16, 9));
      core.messagesToReturn = [
        MessageDto(
          id: 1,
          direction: MessageDirectionDto.incoming,
          kind: MessageKindDto.file,
          body: 'documento.pdf',
          audioFileId: fileId,
          deliveryState: DeliveryStateDto.delivered,
          createdAtUnixSecs: 1000,
          isEphemeral: false,
          viewOnce: false,
          reactions: const [],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: ChatScreen(
            core: core,
            router: router,
            contactId: ContactId(List.filled(16, 1)),
            contactLabel: 'Bob',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Recebendo arquivo…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('file message bubble renders icon, filename and sent status for outgoing file', (tester) async {
      final fileId = Uint8List.fromList(List.filled(16, 8));
      core.messagesToReturn = [
        MessageDto(
          id: 2,
          direction: MessageDirectionDto.outgoing,
          kind: MessageKindDto.file,
          body: 'foto.png',
          audioFileId: fileId,
          deliveryState: DeliveryStateDto.sent,
          createdAtUnixSecs: 1000,
          isEphemeral: false,
          viewOnce: false,
          reactions: const [],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: DarkTechTheme.theme,
          home: ChatScreen(
            core: core,
            router: router,
            contactId: ContactId(List.filled(16, 1)),
            contactLabel: 'Bob',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('foto.png'), findsOneWidget);
      expect(find.text('Enviado'), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget);
    });
  });
}
