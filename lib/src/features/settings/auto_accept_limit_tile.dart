import 'package:flutter/material.dart';
import 'package:viska/src/rust/ffi/core.dart';

const int _kib = 1024;
const int _mib = 1024 * _kib;
const int _gib = 1024 * _mib;

/// Valores oferecidos no menu; 0 significa que todo arquivo pede confirmação.
const List<int> autoAcceptLimitChoices = [0, 25 * _mib, 100 * _mib, 500 * _mib, _gib];

/// Formata bytes em unidades binárias (ex.: `10 MiB`, `1,5 GiB`, `10000 B`).
String formatAutoAcceptLimit(int bytes) {
  if (bytes == 0) return 'Sempre perguntar';
  const units = [(_gib, 'GiB'), (_mib, 'MiB'), (_kib, 'KiB')];
  for (final (size, name) in units) {
    if (bytes >= size) {
      final value = bytes / size;
      final text = value == value.truncateToDouble()
          ? value.toStringAsFixed(0)
          : value.toStringAsFixed(1).replaceAll('.', ',');
      return '$text $name';
    }
  }
  return '$bytes B';
}

/// Item de configurações que lê e grava o teto de auto-aceite de arquivos.
///
/// O valor mostrado é sempre o confirmado pelo core: se a leitura falha, o menu
/// fica desabilitado em vez de assumir o padrão, que poderia diferir do real.
class AutoAcceptLimitTile extends StatefulWidget {
  const AutoAcceptLimitTile({super.key, required this.core});

  final Core core;

  @override
  State<AutoAcceptLimitTile> createState() => _AutoAcceptLimitTileState();
}

class _AutoAcceptLimitTileState extends State<AutoAcceptLimitTile> {
  int? _limit;
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final limit = (await widget.core.autoAcceptFileSizeLimit()).toInt();
      if (!mounted) return;
      setState(() => _limit = limit);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
    }
  }

  Future<void> _change(int? bytes) async {
    if (bytes == null || bytes == _limit || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.core.setAutoAcceptFileSizeLimit(limitBytes: BigInt.from(bytes));
      if (!mounted) return;
      setState(() => _limit = bytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível salvar o limite de auto-aceite.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final limit = _limit;
    final choices = [
      ...autoAcceptLimitChoices,
      if (limit != null && !autoAcceptLimitChoices.contains(limit)) limit,
    ]..sort();

    final subtitle = _loadFailed
        ? 'Não foi possível ler o limite'
        : limit == null
            ? 'Carregando…'
            : limit == 0
                ? 'Todo arquivo recebido pede confirmação'
                : 'Arquivos acima de ${formatAutoAcceptLimit(limit)} pedem confirmação';

    return ListTile(
      leading: const Icon(Icons.download_outlined),
      title: const Text('Auto-aceite de arquivos'),
      subtitle: Text(subtitle),
      trailing: DropdownButton<int>(
        value: limit,
        underline: const SizedBox(),
        items: [
          for (final bytes in choices)
            DropdownMenuItem(value: bytes, child: Text(formatAutoAcceptLimit(bytes))),
        ],
        onChanged: (limit == null || _saving) ? null : _change,
      ),
    );
  }
}
