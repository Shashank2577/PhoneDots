import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../core/version.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Each step PhoneDots took with its models, and anything that failed, to copy
/// into a bug report.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final mono = context.text.bodySmall?.copyWith(fontFamily: 'monospace', fontSize: 12);
    return Scaffold(
      appBar: AppBar(title: const Text('Logs')),
      body: ListenableBuilder(
        listenable: s.log,
        builder: (context, _) {
          final lines = s.log.lines;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  'Each step with your models (downloads, copies from other apps, checksums, loads) and anything that failed. '
                  'Copy it and paste it into a bug report. Kept on this phone only.',
                  style: context.text.bodySmall,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    FilledButton(onPressed: lines.isEmpty ? null : () => _copy(context), child: const Text('Copy all')),
                    const SizedBox(width: 12),
                    OutlinedButton(onPressed: lines.isEmpty ? null : s.log.clear, child: const Text('Clear')),
                    const Spacer(),
                    Text('${lines.length} line${lines.length == 1 ? '' : 's'}', style: context.text.bodySmall),
                  ],
                ),
              ),
              if (lines.isEmpty)
                Panel(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text('Nothing yet.', style: context.text.bodySmall),
                )
              else
                Panel(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: SelectableText(lines.join('\n'), style: mono),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final s = AppScope.services(context);
    final where = s.models.shared?.location.path ?? 'no shared store (${s.platform})';
    final header = 'PhoneDots $appVersion on ${defaultTargetPlatform.name}, models in $where';
    await Clipboard.setData(ClipboardData(text: s.log.text(header: header)));
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied. Paste it into your report.')));
    }
  }
}
