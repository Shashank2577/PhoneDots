import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../core/util/format.dart';
import '../../saved/saved_store.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';
import '../../widgets/local_image.dart';

Doodle platformDoodle(String platform) => switch (platform) {
  'youtube' || 'tiktok' => Doodle.play,
  'instagram' || 'screenshot' => Doodle.camera,
  'github' => Doodle.curl,
  'medium' => Doodle.book,
  'linkedin' => Doodle.person,
  'threads' || 'x' => Doodle.bubble,
  'file' => Doodle.folder,
  _ => Doodle.share,
};

String statusLine(SavedItem i) => switch (i.status) {
  SavedStatus.reading => 'reading',
  SavedStatus.summarising => 'summarising on this phone',
  SavedStatus.needsModel => 'waiting for a model',
  SavedStatus.failed => 'could not summarise',
  SavedStatus.done => '',
};

/// Everything shared into PhoneDots, summarised by Gemma on the phone.
class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  final _query = TextEditingController();
  String? _collection;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _addLink() async {
    final s = AppScope.services(context);
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    final c = TextEditingController(text: clip.contains('http') ? clip.trim() : '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('save a link', style: Hand.title.copyWith(color: ctx.pal.ink)),
            const Meta('Or share it to PhoneDots from any app.'),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'https://…'),
            ),
            const SizedBox(height: 16),
            InkButton('save & summarise', expand: true, onTap: () => Navigator.pop(ctx, true)),
          ],
        ),
      ),
    );
    if (ok == true && c.text.trim().isNotEmpty) {
      await s.receiveShare(text: c.text.trim());
    }
    c.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([s.saved, _query]),
      builder: (context, _) {
        final items = s.saved.search(_query.text, collection: _collection);
        final collections = s.saved.collections;
        return HandPage(
          wordmark: true,
          actions: [DoodleButton(Doodle.plus, tooltip: 'Save a link', onTap: _addLink)],
          children: [
            const PageIntro(
              'saved',
              'Share a post, reel, video or screenshot to PhoneDots. Gemma reads it and files it, right here on the phone.',
              mark: 'right here',
              doodle: Doodle.heart,
            ),
            if (s.saved.items.isNotEmpty) ...[
              TextField(
                controller: _query,
                decoration: InputDecoration(
                  hintText: 'search what you saved',
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DoodleIcon(Doodle.search, size: 18, color: p.pencil),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (collections.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoicePill(
                      'everything',
                      selected: _collection == null,
                      onTap: () => setState(() => _collection = null),
                    ),
                    for (final c in collections)
                      ChoicePill(
                        c,
                        selected: _collection == c,
                        onTap: () => setState(() => _collection = _collection == c ? null : c),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
            ],
            if (s.saved.items.isEmpty)
              HandEmpty(
                title: 'nothing saved yet',
                body: 'In Instagram, TikTok, YouTube or any app, tap share and pick PhoneDots. Or save a link here.',
                doodle: Doodle.share,
                action: PillButton('save a link', leading: Doodle.plus, onTap: _addLink),
              )
            else if (items.isEmpty)
              const HandEmpty(title: 'nothing matches', doodle: Doodle.search),
            for (final (i, item) in items.indexed)
              Enter(
                index: i,
                child: _SavedRow(
                  item,
                  onTap: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => SavedDetailScreen(id: item.id))),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow(this.item, {required this.onTap});
  final SavedItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final status = statusLine(item);
    return Pressable(
      onTap: onTap,
      scale: 0.99,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DoodleIcon(platformDoodle(item.platform), size: 20, color: p.pencil),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayTitle,
                        style: Hand.label.copyWith(fontSize: 23, color: p.ink),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.summary != null) Meta(item.summary!, maxLines: 2),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (item.busy) ...[const HoppingDots(size: 5), const SizedBox(width: 6)],
                          Expanded(
                            child: Meta(
                              [
                                if (status.isNotEmpty) status,
                                if (item.collection != null) item.collection!,
                                if (item.author != null) item.author!,
                                timeAgo(item.created),
                              ].join(' · '),
                              color: item.status == SavedStatus.failed ? p.redPen : null,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (item.imagePath != null) ...[
                  const SizedBox(width: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: localImage(item.imagePath!, width: 56, height: 56),
                  ),
                ],
              ],
            ),
            const HandDivider(padding: EdgeInsets.only(top: 10)),
          ],
        ),
      ),
    );
  }
}

class SavedDetailScreen extends StatelessWidget {
  const SavedDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: s.saved,
      builder: (context, _) {
        final item = s.saved.byId(id);
        if (item == null)
          return const HandPage(
            children: [HandEmpty(title: 'gone', doodle: Doodle.trash)],
          );
        final status = statusLine(item);
        return HandPage(
          actions: [
            DoodleButton(
              Doodle.trash,
              tooltip: 'Delete',
              onTap: () async {
                if (await confirmDialog(context, title: 'delete this?', confirm: 'delete', destructive: true)) {
                  await s.saved.remove(item);
                  if (context.mounted) Navigator.of(context).maybePop();
                }
              },
            ),
          ],
          children: [
            Row(
              children: [
                DoodleIcon(platformDoodle(item.platform), size: 18, color: p.pencil),
                const SizedBox(width: 8),
                Expanded(
                  child: Meta(
                    [
                      item.platform,
                      if (item.kind != 'link') item.kind,
                      if (item.author != null) item.author!,
                      timeAgo(item.created),
                    ].join(' · '),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(item.displayTitle, style: Hand.headline.copyWith(fontSize: 34, color: p.ink)),
            if (item.imagePath != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: localImage(item.imagePath!, width: double.infinity, height: 220),
              ),
            ],
            if (item.busy) ...[
              const SizedBox(height: 18),
              Row(children: [const HoppingDots(), const SizedBox(width: 10), Meta('$status…')]),
            ],
            if (item.summary != null) ...[const SectionHead('in short', mark: true), Body(item.summary!)],
            if (item.points.isNotEmpty) ...[
              const SectionHead('key points'),
              for (final pt in item.points)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: DoodleIcon(Doodle.tick, size: 16, color: p.pencil),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Body(pt)),
                    ],
                  ),
                ),
            ],
            if (item.status == SavedStatus.needsModel || item.status == SavedStatus.failed) ...[
              const SizedBox(height: 14),
              Body(item.error ?? 'Not summarised yet.', color: item.status == SavedStatus.failed ? p.redPen : p.pencil),
            ],
            if (item.tags.isNotEmpty || item.collection != null) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (item.collection != null) HandTag(item.collection!, marked: true),
                  for (final t in item.tags) HandTag('#$t'),
                ],
              ),
            ],
            if (item.sharedText.isNotEmpty || (item.description ?? '').isNotEmpty) ...[
              const SectionHead('what was shared'),
              if (item.sharedText.isNotEmpty) Meta(item.sharedText),
              if ((item.description ?? '').isNotEmpty) Meta(item.description!, maxLines: 12),
            ],
            if (item.sources.isNotEmpty) ...[
              const SizedBox(height: 12),
              Meta('read from: ${item.sources.join(', ')} · summarised on this phone'),
            ],
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.url != null)
                  PillButton(
                    'open',
                    leading: Doodle.arrow,
                    onTap: () => s.device.invoke('url.open', {'url': item.url}),
                  ),
                PillButton(
                  'chat about it',
                  leading: Doodle.bubble,
                  onTap: () {
                    final state = AppScope.of(context);
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    state.startChat(
                      (chat) => chat.send(
                        [
                          'Tell me more about this, which I saved:',
                          if (item.url != null) item.url!,
                          if (item.url == null) item.displayTitle,
                          if (item.summary != null) 'Summary so far: ${item.summary}',
                        ].join('\n'),
                        attachments: [
                          for (final (n, f) in item.files.indexed)
                            Attachment(
                              id: 'a${n + 1}',
                              kind: f['kind'] ?? 'document',
                              path: f['path'] ?? '',
                              name: f['name'] ?? '',
                            ),
                        ],
                      ),
                    );
                  },
                ),
                if (!item.busy)
                  PillButton(
                    item.summary == null ? 'summarise' : 'summarise again',
                    leading: Doodle.pen,
                    onTap: () => s.summarizer.resummarise(item),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
