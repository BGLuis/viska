import 'package:flutter/material.dart';
import 'package:viska/src/rust/ffi/types.dart';

/// Renderiza um [SafetyNumberDto] nas duas formas da spec §3.3: 12 grupos de
/// 5 dígitos (comparação visual) e 6 palavras (leitura em voz alta por um
/// canal de áudio confiável).
///
/// Widget puro — recebe o DTO já pronto, sem chamar o FFI. Isso é o que
/// permite testar a renderização sem identidade nem banco de verdade.
class SafetyNumberView extends StatelessWidget {
  const SafetyNumberView({super.key, required this.safetyNumber});

  final SafetyNumberDto safetyNumber;

  @override
  Widget build(BuildContext context) {
    final digitGroups = safetyNumber.digits.split(' ');
    final words = safetyNumber.words.split(' ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          key: const ValueKey('safety_number_digits'),
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final group in digitGroups)
              Text(
                group,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          key: const ValueKey('safety_number_words'),
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final word in words)
              Text(word, style: const TextStyle(fontSize: 16, fontStyle: FontStyle.italic)),
          ],
        ),
      ],
    );
  }
}
