// `StreamAudioSource`/`StreamAudioResponse` são marcados `@experimental` pelo just_audio.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:viska/src/features/voice/voice_io.dart';
import 'package:viska/src/theme/dark_tech_theme.dart';

/// Reprodutor de notas de voz de alta fidelidade com visualização interativa
/// de waveform, arraste (scrubber) e controle de velocidade cíclica (1.0x, 1.5x, 2.0x).
class AudioWaveformPlayer extends StatefulWidget {
  const AudioWaveformPlayer({
    super.key,
    required this.audioBytes,
    this.player,
    this.barCount = 36,
    this.activeColor = DarkTechTheme.primary,
    this.inactiveColor = const Color(0xFF283445),
    this.speedColor = DarkTechTheme.secondary,
  });

  /// Bytes de áudio decodificados em formato WAV (D18).
  final Uint8List? audioBytes;

  /// Player opcional injetável para testes. Se nulo, cria um `AudioPlayer` interno.
  final AudioPlayer? player;

  /// Quantidade de barras exibidas na visualização da onda.
  final int barCount;

  /// Cor da porção reproduzida da onda.
  final Color activeColor;

  /// Cor da porção restante da onda.
  final Color inactiveColor;

  /// Cor de destaque do botão de velocidade acelerada.
  final Color speedColor;

  @override
  State<AudioWaveformPlayer> createState() => _AudioWaveformPlayerState();
}

class _AudioWaveformPlayerState extends State<AudioWaveformPlayer> {
  late final AudioPlayer _player;
  late final bool _isExternalPlayer;

  late List<double> _waveformLevels;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  double _speed = 1.0;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  @override
  void initState() {
    super.initState();
    _isExternalPlayer = widget.player != null;
    _player = widget.player ?? AudioPlayer();

    _waveformLevels = _extractWaveformPeaks(widget.audioBytes, widget.barCount);
    _initAudio();
  }

  @override
  void didUpdateWidget(covariant AudioWaveformPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioBytes != widget.audioBytes) {
      _waveformLevels = _extractWaveformPeaks(widget.audioBytes, widget.barCount);
      _initAudio();
    }
  }

  Future<void> _initAudio() async {
    final bytes = widget.audioBytes;
    if (bytes == null || bytes.isEmpty) return;

    try {
      await _player.setAudioSource(BytesAudioSource(bytes));
      if (!mounted) return;

      _stateSub?.cancel();
      _stateSub = _player.playerStateStream.listen((state) {
        if (!mounted) return;
        final playing = state.playing && state.processingState != ProcessingState.completed;
        setState(() {
          _isPlaying = playing;
          if (state.processingState == ProcessingState.completed) {
            _position = Duration.zero;
            _player.seek(Duration.zero);
            _player.pause();
          }
        });
      });

      _positionSub?.cancel();
      _positionSub = _player.positionStream.listen((pos) {
        if (!mounted) return;
        setState(() => _position = pos);
      });

      _durationSub?.cancel();
      _durationSub = _player.durationStream.listen((dur) {
        if (!mounted) return;
        if (dur != null) {
          setState(() => _duration = dur);
        }
      });
    } catch (_) {
      // Ignora falhas silenciosamente em testes ou codecs de plataforma não inicializados
    }
  }

  Future<void> _togglePlayPause() async {
    if (widget.audioBytes == null || widget.audioBytes!.isEmpty) return;

    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        if (_position >= _duration && _duration > Duration.zero) {
          await _player.seek(Duration.zero);
        }
        await _player.play();
      }
    } catch (_) {}
  }

  void _cycleSpeed() {
    final nextSpeed = _speed == 1.0
        ? 1.5
        : _speed == 1.5
            ? 2.0
            : 1.0;

    setState(() => _speed = nextSpeed);
    try {
      _player.setSpeed(nextSpeed);
    } catch (_) {}
  }

  void _seekByFraction(double fraction) {
    if (_duration == Duration.zero) return;
    final targetMs = (_duration.inMilliseconds * fraction.clamp(0.0, 1.0)).round();
    final target = Duration(milliseconds: targetMs);
    setState(() => _position = target);
    try {
      _player.seek(target);
    } catch (_) {}
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    if (!_isExternalPlayer) {
      _player.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progressFraction = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      decoration: BoxDecoration(
        color: DarkTechTheme.surfaceContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DarkTechTheme.divider, width: 1.0),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Botão Play / Pause
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _togglePlayPause,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isPlaying
                          ? widget.activeColor.withValues(alpha: 0.2)
                          : DarkTechTheme.surface,
                      border: Border.all(
                        color: _isPlaying ? widget.activeColor : DarkTechTheme.divider,
                        width: 1.2,
                      ),
                    ),
                    child: Icon(
                      _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: _isPlaying ? widget.activeColor : DarkTechTheme.textPrimary,
                      size: 24,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Barras de Waveform interativas com scrubber
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        final fraction = details.localPosition.dx / constraints.maxWidth;
                        _seekByFraction(fraction);
                      },
                      onTapDown: (details) {
                        final fraction = details.localPosition.dx / constraints.maxWidth;
                        _seekByFraction(fraction);
                      },
                      child: SizedBox(
                        height: 38,
                        child: CustomPaint(
                          size: Size(constraints.maxWidth, 38),
                          painter: _WaveformPainter(
                            waveformLevels: _waveformLevels,
                            progress: progressFraction,
                            activeColor: widget.activeColor,
                            inactiveColor: widget.inactiveColor,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),

              // Botão de alternância de velocidade cíclica (1.0x -> 1.5x -> 2.0x)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _cycleSpeed,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: _speed > 1.0
                          ? widget.speedColor.withValues(alpha: 0.15)
                          : DarkTechTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _speed > 1.0 ? widget.speedColor : DarkTechTheme.divider,
                        width: 1.0,
                      ),
                    ),
                    child: Text(
                      '${_speed.toStringAsFixed(_speed % 1 == 0 ? 0 : 1)}x',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: _speed > 1.0 ? widget.speedColor : DarkTechTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Rodapé com tempo decorrido e duração total
          Padding(
            padding: const EdgeInsets.only(left: 48, right: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: DarkTechTheme.textSecondary,
                  ),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: DarkTechTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// Extrai os picos de amplitude a partir de dados WAV PCM 16-bit ou gera
  /// uma onda determinística esteticamente consistente se o cabeçalho for ausente.
  static List<double> _extractWaveformPeaks(Uint8List? bytes, int count) {
    if (bytes == null || bytes.length < 44) {
      return List.generate(
        count,
        (i) => 0.25 + 0.6 * sin((i / count) * pi * 2).abs(),
      );
    }

    try {
      // Localiza o chunk 'data' no contêiner RIFF/WAVE
      int dataOffset = 44;
      for (int i = 12; i < bytes.length - 8; i++) {
        if (bytes[i] == 0x64 &&
            bytes[i + 1] == 0x61 &&
            bytes[i + 2] == 0x74 &&
            bytes[i + 3] == 0x61) {
          dataOffset = i + 8;
          break;
        }
      }

      final sampleCount = (bytes.length - dataOffset) ~/ 2;
      if (sampleCount < count) {
        return List.generate(count, (i) => 0.3 + 0.4 * ((i % 5) / 5));
      }

      final samplesPerBar = sampleCount ~/ count;
      final peaks = <double>[];

      for (int bar = 0; bar < count; bar++) {
        int maxAmp = 0;
        final startSample = bar * samplesPerBar;
        final endSample = (bar + 1) * samplesPerBar;

        for (int s = startSample; s < endSample && (dataOffset + s * 2 + 1) < bytes.length; s += 2) {
          final byte1 = bytes[dataOffset + s * 2];
          final byte2 = bytes[dataOffset + s * 2 + 1];
          // 16-bit signed little-endian
          int sample = byte1 | (byte2 << 8);
          if (sample >= 0x8000) sample -= 0x10000;
          final abs = sample.abs();
          if (abs > maxAmp) maxAmp = abs;
        }

        // Normaliza entre 0.15 e 1.0 para manter barras visíveis mesmo em silêncio
        final normalized = (maxAmp / 32768.0).clamp(0.0, 1.0);
        peaks.add(0.15 + (normalized * 0.85));
      }

      return peaks;
    } catch (_) {
      return List.generate(count, (i) => 0.25 + 0.5 * ((i * 7 % 11) / 11));
    }
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.waveformLevels,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  final List<double> waveformLevels;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (waveformLevels.isEmpty) return;

    final barCount = waveformLevels.length;
    const spacingRatio = 0.35;
    final totalSpacingUnits = (barCount - 1) * spacingRatio;
    final barWidth = size.width / (barCount + totalSpacingUnits);
    final spacing = barWidth * spacingRatio;

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;

    final progressX = size.width * progress;

    for (int i = 0; i < barCount; i++) {
      final x = i * (barWidth + spacing);
      final level = waveformLevels[i].clamp(0.12, 1.0);
      final barHeight = size.height * level;
      final y = (size.height - barHeight) / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );

      final isBarActive = (x + barWidth / 2) <= progressX;
      canvas.drawRRect(rect, isBarActive ? activePaint : inactivePaint);
    }

    // Ponto indicador do scrubber atual
    if (progress > 0.0 && progress < 1.0) {
      final scrubberPaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(progressX.clamp(3.0, size.width - 3.0), size.height / 2),
        3.0,
        scrubberPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.waveformLevels != waveformLevels;
  }
}
