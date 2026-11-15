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
import '../../widgets/rich_text.dart';

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
  ValueNotifier<String?>? _arrived;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_arrived == null) {
      _arrived = AppScope.services(context).savedArrived..addListener(_openArrived);
      WidgetsBinding.instance.addPostFrameCallback((_) => _openArrived());
    }
  }

  /// A fresh share opens straight onto its page: text first, summary as it comes.
  void _openArrived() {
    final id = _arrived?.value;
    if (id == null || !mounted) return;
    _arrived!.value = null;
    Navigator.of(context).popUntil((r) => r.isFirst);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SavedDetailScreen(id: id)));
  }

  @override
  void dispose() {
    _arrived?.removeListener(_openArrived);
    _query.dispose();
    super.dispose();
  }

  Future<void> _addLink() async {
    final s = AppScope.services(context);
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddLinkSheet(initial: clip.contains('http') ? clip.trim() : ''),
    );
    if (text != null && text.trim().isNotEmpty) await s.receiveShare(text: text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([s.saved, _query]),
      builder: (context, _) {
        final collections = s.saved.collections;
        // A filter whose collection has gone (its last item deleted) no longer applies.
        if (_collection != null && !collections.contains(_collection)) _collection = null;
        final items = s.saved.search(_query.text, collection: _collection);
        return HandPage(
          wordmark: true,
          actions: [DoodleButton(Doodle.plus, tooltip: 'Save a link', onTap: _addLink)],
          children: [
            const PageIntro(
              'saved',
              'Share a post, video or screenshot to PhoneDots and Gemma files it, right here on the phone.',
            ),
            if (s.saved.items.isNotEmpty) ...[
              TextField(
                controller: _query,
                decoration: InputDecoration(
                  hintText: 'search what you saved',
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(14),
                    child: DoodleIcon(Doodle.search, size: 20, color: p.pencil),
                  ),
                ),
              ),
              if (collections.isNotEmpty)
                // One line of filters that scrolls sideways.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      ChoicePill(
                        'everything',
                        selected: _collection == null,
                        onTap: () => setState(() => _collection = null),
                      ),
                      for (final c in collections) ...[
                        const SizedBox(width: 8),
                        ChoicePill(
                          c,
                          selected: _collection == c,
                          onTap: () => setState(() => _collection = _collection == c ? null : c),
                        ),
                      ],
                    ],
                  ),
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

/// One saved post: its title, the summary, and where and when it came from.
class _SavedRow extends StatelessWidget {
  const _SavedRow(this.item, {required this.onTap});
  final SavedItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final status = statusLine(item);
    return Column(
      children: [
        ItemRow(
          title: item.displayTitle,
          meta: item.summary,
          caption: [
            if (status.isNotEmpty) status,
            if (item.collection != null) item.collection!,
            if (item.author != null) item.author!,
            timeAgo(item.created),
          ].join(' · '),
          captionColor: item.status == SavedStatus.failed ? p.redPen : null,
          leading: DoodleIcon(platformDoodle(item.platform), size: 24, color: p.pencil),
          trailing: item.imagePath != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: localImage(item.imagePath!, width: 56, height: 56),
                )
              : null,
          onTap: onTap,
        ),
        HandDivider(padding: EdgeInsets.zero, seed: item.id.hashCode & 0xff),
      ],
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
        if (item == null) {
          return const HandPage(
            children: [HandEmpty(title: 'gone', doodle: Doodle.trash)],
          );
        }
        final status = statusLine(item);
        final read = [
          if (item.sharedText.isNotEmpty) item.sharedText,
          if ((item.body ?? '').isNotEmpty) item.body!,
        ];
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
                DoodleIcon(platformDoodle(item.platform), size: 20, color: p.pencil),
                const SizedBox(width: 8),
                Expanded(
                  child: Caption(
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
            SelectableText(item.displayTitle, style: context.type.contentTitle),
            if (item.imagePath != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: localImage(item.imagePath!, width: double.infinity, height: 220),
              ),
            ],
            if (item.busy) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const HoppingDots(),
                  const SizedBox(width: 10),
                  Expanded(child: Caption('${status[0].toUpperCase()}${status.substring(1)}…')),
                ],
              ),
            ],
            // The summary first; the raw text it came from is behind a link at the bottom.
            if (item.summary != null) ...[const SizedBox(height: 16), Prose(item.summary!)],
            // Until there is a summary, the post's own caption stands in for it.
            if (item.summary == null && (item.description ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              Prose(item.description!),
            ],
            if (item.points.isNotEmpty) ...[
              const SectionHead('key points'),
              for (final pt in item.points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: DoodleIcon(Doodle.tick, size: 18, color: p.pencil),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: SelectableText(pt, style: context.type.reading)),
                    ],
                  ),
                ),
            ],
            if (item.status == SavedStatus.needsModel || item.status == SavedStatus.failed) ...[
              const SizedBox(height: 16),
              item.status == SavedStatus.failed
                  ? Warning(item.error ?? 'Could not summarise this.')
                  : Body(item.error ?? 'Not summarised yet.'),
            ],
            if (read.isEmpty && !item.busy && item.url != null && item.summary == null) ...[
              const SizedBox(height: 12),
              const Body(
                'The site shared no text for this post. Share a screenshot or a screen recording and PhoneDots will read that.',
              ),
            ],
            if (item.tags.isNotEmpty || item.collection != null) ...[
              const SizedBox(height: 20),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (item.collection != null) HandTag(item.collection!),
                  for (final t in item.tags) HandTag('#$t'),
                ],
              ),
            ],
            if (item.sources.isNotEmpty) ...[
              const SizedBox(height: 12),
              Caption('Read from ${item.sources.join(', ')} · summarised on this phone'),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.url != null)
                  PillButton(
                    'open the original',
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
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (item.summary != null)
                  HandLink(
                    'copy the summary',
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: [
                            item.displayTitle,
                            item.summary!,
                            for (final pt in item.points) '• $pt',
                            if (item.url != null) item.url!,
                          ].join('\n'),
                        ),
                      );
                      toast(context, 'copied');
                    },
                  ),
                if (!item.busy)
                  HandLink(
                    item.summary == null ? 'summarise' : 'summarise again',
                    onTap: () => s.summarizer.resummarise(item),
                  ),
                if (read.isNotEmpty)
                  HandLink('what we read', onTap: () => _showRead(context, item)),
              ],
            ),
            if (read.isNotEmpty)
              Caption('${read.fold<int>(0, (a, t) => a + t.length)} characters of text, kept on this phone'),
          ],
        );
      },
    );
  }
}

/// The raw text PhoneDots read for a post: what was shared with it, and the page or caption.
void _showRead(BuildContext context, SavedItem item) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (c) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.8,
    builder: (_, controller) => ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
      children: [
        const PageIntro('what we read', 'The text Gemma summarised, as it came from the site.'),
        if (item.sharedText.isNotEmpty) ...[
          const SectionHead('shared with it', first: true),
          SelectableText(item.sharedText, style: context.type.body),
        ],
        if ((item.body ?? '').isNotEmpty) ...[
          SectionHead('the page', first: item.sharedText.isEmpty),
          FullText(item.body!),
          Align(
            alignment: Alignment.centerLeft,
            child: HandLink(
              'copy the text',
              onTap: () {
                Clipboard.setData(ClipboardData(text: item.body!));
                toast(context, 'copied');
              },
            ),
          ),
        ],
      ],
    ),
  ),
);

/// Long text (a README, an article, a transcript) folded to a few lines until tapped.
class FullText extends StatefulWidget {
  const FullText(this.text, {super.key});
  final String text;

  @override
  State<FullText> createState() => _FullTextState();
}

class _FullTextState extends State<FullText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > 2500;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          alignment: Alignment.topCenter,
          child: SelectableText(
            !_open && long ? '${widget.text.substring(0, 2500)}…' : widget.text,
            style: context.type.body,
          ),
        ),
        if (long)
          HandLink(
            _open ? 'fold it up' : 'read all ${(widget.text.length / 1000).toStringAsFixed(1)}k characters',
            onTap: () => setState(() => _open = !_open),
          ),
      ],
    );
  }
}

/// "save a link": owns its text controller, so closing never touches a disposed one.
class _AddLinkSheet extends StatefulWidget {
  const _AddLinkSheet({required this.initial});
  final String initial;

  @override
  State<_AddLinkSheet> createState() => _AddLinkSheetState();
}

class _AddLinkSheetState extends State<_AddLinkSheet> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 20 + MediaQuery.of(context).viewInsets.bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('save a link', style: Hand.title.copyWith(color: context.pal.ink), textScaler: Hand.scaler(context)),
        const Meta('Or share it to PhoneDots from any app.'),
        const SizedBox(height: 12),
        TextField(
          controller: _c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        const SizedBox(height: 16),
        InkButton('save & summarise', expand: true, onTap: () => Navigator.pop(context, _c.text)),
      ],
    ),
  );
}
