// `StreamAudioSource`/`StreamAudioResponse` são marcados `@experimental` pelo
// `just_audio` — API pública documentada, não uma dica de bug.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

/// Taxa de amostragem e canais fixos para toda nota de voz — os dois lados
/// nunca precisam negociar codec. Mono: voz não precisa de estéreo. Ver
/// armadilha do relatório da Fase 5 ("iOS entrega AAC por padrão; Opus
/// exige configuração explícita") — o mesmo vale para Android (SDK 29+).
const kVoiceSampleRate = 48000;
const kVoiceChannels = 1;

/// Grava áudio em Opus — extraída como interface só para poder injetar um
/// dublê em teste (`AudioRecorder`, do pacote `record`, é uma classe
/// concreta ligada a canal de plataforma).
abstract class VoiceRecorder {
  /// Começa a gravar em `path`. Lança se o aparelho não suportar Opus —
  /// quem chama decide como comunicar isso ao usuário; esta interface não
  /// esconde a falha caindo em outro codec.
  Future<void> start(String path);

  /// Para a gravação e devolve o caminho gravado, ou `null` se nada foi
  /// gravado (chamado sem `start` correspondente).
  Future<String?> stop();

  Future<void> dispose();
}

class RecordVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _inner = AudioRecorder();

  @override
  Future<void> start(String path) => _inner.start(
        const RecordConfig(
          encoder: AudioEncoder.opus,
          sampleRate: kVoiceSampleRate,
          numChannels: kVoiceChannels,
        ),
        path: path,
      );

  @override
  Future<String?> stop() => _inner.stop();

  @override
  Future<void> dispose() => _inner.dispose();
}

/// Toca bytes de áudio já em memória — extraída como interface pelo mesmo
/// motivo de [VoiceRecorder]. Sempre WAV (D18): `AVPlayer` no iOS não
/// demuxa Ogg, com ou sem suporte a Opus.
abstract class VoicePlayer {
  Future<void> playBytes(Uint8List wavBytes);
  Future<void> stop();
  Future<void> dispose();
}

class JustAudioVoicePlayer implements VoicePlayer {
  final AudioPlayer _inner = AudioPlayer();

  @override
  Future<void> playBytes(Uint8List wavBytes) async {
    await _inner.setAudioSource(_BytesAudioSource(wavBytes));
    await _inner.play();
  }

  @override
  Future<void> stop() => _inner.stop();

  @override
  Future<void> dispose() => _inner.dispose();
}

/// Fonte de áudio do `just_audio` a partir de bytes já em memória — nunca
/// toca disco. `audioplayers`/`BytesSource` foi descartado para isto: não
/// tem suporte em iOS/macOS (`hasBytesSource: false` no Darwin).
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this._bytes) : super(tag: 'nota-de-voz');

  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final rangeStart = start ?? 0;
    final rangeEnd = end ?? _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: rangeEnd - rangeStart,
      offset: rangeStart,
      stream: Stream.value(_bytes.sublist(rangeStart, rangeEnd)),
      contentType: 'audio/wav',
    );
  }
}
