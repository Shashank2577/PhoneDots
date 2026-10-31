import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([s.ledger, s.conversations, s.memory, s.knowledge, s.saved]),
      builder: (context, _) {
        final entries = s.ledger.entries;
        return HandPage(
          children: [
            const MarkedText('what you keep stays on this phone.', mark: 'stays', style: Hand.headline),
            const SizedBox(height: 8),
            Body(
              'PhoneDots has made ${s.ledger.networkEvents} network requests: model downloads and the links you shared, '
              'each listed below. Chats, recordings, photos, memory, saved posts and summaries are only ever processed here. '
              'No account, no analytics.',
              color: p.pencil,
            ),
            const SectionHead('kept on this phone'),
            Row(
              children: [
                _Count('${s.conversations.summaries.length}', 'chats'),
                _Count('${s.saved.items.length}', 'saved'),
                _Count('${s.memory.facts.length}', 'memories'),
                _Count('${s.knowledge.docs.length}', 'files'),
                _Count('${entries.length}', 'log lines'),
              ],
            ),
            const HandDivider(padding: EdgeInsets.symmetric(vertical: 16)),
            const SectionHead('forget', padding: EdgeInsets.zero),
            _EraseTile(label: 'all chats', onConfirm: s.conversations.deleteAll),
            _EraseTile(label: 'saved posts', onConfirm: s.saved.clear),
            _EraseTile(label: 'memory', onConfirm: s.memory.clear),
            _EraseTile(label: 'my files index', onConfirm: s.knowledge.clear),
            _EraseTile(label: 'activity log', onConfirm: s.ledger.clear),
            _EraseTile(label: 'skill permissions', onConfirm: () => s.settings.update((x) => x.grantedSkills.clear())),
            const SectionHead('what it did'),
            if (entries.isEmpty) const HandEmpty(title: 'nothing yet', doodle: Doodle.squiggle),
            for (final e in entries.take(200))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DoodleIcon(e.network ? Doodle.arrow : Doodle.tick, size: 18, color: e.network ? p.ink : p.pencil),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.detail, style: Hand.small.copyWith(fontSize: 20, color: p.ink)),
                          Meta('${e.kind} · ${timeAgo(e.time)}${e.network ? ' · used the network' : ''}'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: Hand.title.copyWith(color: context.pal.ink)),
        Meta(label),
      ],
    ),
  );
}

class _EraseTile extends StatelessWidget {
  const _EraseTile({required this.label, required this.onConfirm});
  final String label;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Hand.label.copyWith(fontSize: 23, color: context.pal.ink)),
        ),
        PillButton(
          'forget',
          color: context.pal.redPen,
          onTap: () async {
            if (await confirmDialog(
              context,
              title: 'forget $label?',
              body: 'This can\'t be undone.',
              confirm: 'forget',
              destructive: true,
            )) {
              await onConfirm();
              if (context.mounted) toast(context, '$label forgotten');
            }
          },
        ),
      ],
    ),
  );
}
