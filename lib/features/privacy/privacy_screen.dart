import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.ledger, s.conversations, s.memory, s.knowledge]),
        builder: (context, _) {
          final entries = s.ledger.entries;
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            Panel(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Dot(color: p.dot, size: 10), const SizedBox(width: 10), Text('Nothing you say leaves this phone', style: context.text.titleMedium)]),
                const SizedBox(height: 10),
                Text(
                  'Chats, recordings, photos, memory and files are processed by models on this device. '
                  'The network is used only to download models and community skills, and every such event is listed below.',
                  style: context.text.bodySmall,
                ),
                const SizedBox(height: 16),
                Row(children: [
                  _Count('${s.ledger.networkEvents}', 'network events'),
                  _Count('${s.conversations.summaries.length}', 'chats'),
                  _Count('${s.memory.facts.length}', 'memories'),
                  _Count('${s.knowledge.docs.length}', 'files'),
                ]),
              ]),
            ),
            const SectionLabel('Erase'),
            _EraseTile(label: 'All chats', onConfirm: s.conversations.deleteAll),
            _EraseTile(label: 'Memory', onConfirm: s.memory.clear),
            _EraseTile(label: 'My files index', onConfirm: s.knowledge.clear),
            _EraseTile(label: 'Activity log', onConfirm: s.ledger.clear),
            _EraseTile(label: 'Skill permissions', onConfirm: () => s.settings.update((x) => x.grantedSkills.clear())),
            const SectionLabel('Activity'),
            if (entries.isEmpty) const EmptyState(icon: Icons.receipt_long_outlined, title: 'No activity yet'),
            for (final e in entries.take(200))
              ListTile(
                dense: true,
                leading: Icon(e.network ? Icons.cloud_download_outlined : Icons.phone_android_rounded, size: 18, color: e.network ? p.warn : p.muted),
                title: Text(e.detail, style: context.text.bodyMedium),
                subtitle: Text('${e.kind} · ${timeAgo(e.time)}${e.network ? ' · network' : ''}'),
              ),
          ]);
        },
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: context.text.titleLarge),
          Text(label, style: context.text.bodySmall),
        ]),
      );
}

class _EraseTile extends StatelessWidget {
  const _EraseTile({required this.label, required this.onConfirm});
  final String label;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(label),
        trailing: Text('Erase', style: TextStyle(color: context.pal.danger, fontWeight: FontWeight.w600)),
        onTap: () async {
          if (await confirmDialog(context, title: 'Erase $label?', body: 'This cannot be undone.', confirm: 'Erase', destructive: true)) {
            await onConfirm();
            if (context.mounted) toast(context, '$label erased');
          }
        },
      );
}
