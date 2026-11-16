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
            ),
            const SectionHead('kept on this phone'),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _Count('${s.conversations.summaries.length}', 'chats'),
                _Count('${s.saved.items.length}', 'saved'),
                _Count('${s.memory.facts.length}', 'memories'),
                _Count('${s.knowledge.docs.length}', 'files'),
                _Count('${entries.length}', 'log lines'),
              ],
            ),
            const SectionHead('forget', note: 'Each asks first. None of it can be undone.'),
            _EraseRow(label: 'all chats', onConfirm: s.conversations.deleteAll),
            _EraseRow(label: 'saved posts', onConfirm: s.saved.clear),
            _EraseRow(label: 'memory', onConfirm: s.memory.clear),
            _EraseRow(label: 'my files index', onConfirm: s.knowledge.clear),
            _EraseRow(label: 'activity log', onConfirm: s.ledger.clear),
            _EraseRow(label: 'skill permissions', onConfirm: () => s.settings.update((x) => x.grantedSkills.clear())),
            const SectionHead('what it did'),
            if (entries.isEmpty) const HandEmpty(title: 'nothing yet', doodle: Doodle.squiggle),
            for (final e in entries.take(200))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: DoodleIcon(
                        e.network ? Doodle.arrow : Doodle.tick,
                        size: 18,
                        color: e.network ? p.ink : p.pencil,
                        semanticLabel: e.network ? 'used the network' : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.detail, style: context.type.rowNote),
                          Caption('${e.kind} · ${timeAgo(e.time)}${e.network ? ' · used the network' : ''}'),
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: context.type.rowTitle),
      Caption(label),
    ],
  );
}

/// One thing that can be forgotten: its name and a red "forget" link that asks first.
class _EraseRow extends StatelessWidget {
  const _EraseRow({required this.label, required this.onConfirm});
  final String label;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Body(label)),
      HandLink(
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
  );
}
