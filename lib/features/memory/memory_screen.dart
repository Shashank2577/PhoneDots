import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/util/files.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';
import '../../widgets/rich_text.dart';

/// Everything the assistant was asked to remember, fully editable.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final r = await askSheet(
      context,
      title: 'remember',
      fields: const [(hint: 'e.g. Prefers metric units', lines: 1)],
      confirm: 'remember it',
    );
    final text = r?.first.trim() ?? '';
    if (text.isNotEmpty && context.mounted) await AppScope.services(context).memory.add(text);
  }

  @override
  Widget build(BuildContext context) {
    final memory = AppScope.services(context).memory;
    return ListenableBuilder(
      listenable: memory,
      builder: (context, _) => HandPage(
        bottom: InkButton('remember something', trailing: Doodle.plus, expand: true, onTap: () => _add(context)),
        children: [
          const PageIntro(
            'memory',
            'Things you asked PhoneDots to remember. The model reads them at the start of every chat; nothing else is kept.',
          ),
          if (memory.facts.isEmpty)
            const HandEmpty(
              title: 'nothing remembered',
              body: 'Say "remember that…" in chat, or add one here.',
              doodle: Doodle.heart,
            ),
          for (final (i, f) in memory.facts.indexed)
            Enter(
              index: i,
              // The user's own words: body face, in ink, with when it was added.
              child: ItemRow(
                title: f.text,
                titleStyle: context.type.body,
                titleLines: 4,
                caption: timeAgo(f.created),
                trailing: DoodleButton(
                  Doodle.trash,
                  tooltip: 'Forget',
                  size: 20,
                  color: context.pal.pencil,
                  onTap: () => memory.remove(f),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The searchable knowledge base ("my files").
class KnowledgeScreen extends StatefulWidget {
  const KnowledgeScreen({super.key});

  @override
  State<KnowledgeScreen> createState() => _KnowledgeScreenState();
}

class _KnowledgeScreenState extends State<KnowledgeScreen> {
  final _query = TextEditingController();
  List<Map<String, dynamic>> _hits = const [];

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final hits = await AppScope.services(context).knowledge.search(_query.text);
    setState(() => _hits = hits);
  }

  Future<void> _addNote() async {
    final r = await askSheet(
      context,
      title: 'new note',
      fields: const [(hint: 'Title', lines: 1), (hint: 'Text', lines: 4)],
    );
    if (r == null || r[1].trim().isEmpty || !mounted) return;
    await AppScope.services(context).knowledge.add(r[0].trim().isEmpty ? 'Note' : r[0].trim(), r[1], source: 'notes');
  }

  Future<void> _import() async {
    final kb = AppScope.services(context).knowledge;
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['txt', 'md', 'csv', 'json', 'srt']);
    if (f == null) return;
    final text = kIsWeb || f.path == null
        ? utf8.decode(await f.readAsBytes(), allowMalformed: true)
        : await readTextFile(f.path!);
    if (text == null || text.trim().isEmpty) {
      if (mounted) toast(context, 'That file has no readable text.');
      return;
    }
    await kb.add(f.name, text, source: 'import');
    if (mounted) toast(context, 'Added ${f.name}');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final kb = s.knowledge;
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([kb, s.models]),
      builder: (context, _) {
        final semantic = s.models.isReady(s.settings.embedderId) && !s.isDemo;
        return HandPage(
          actions: [
            DoodleButton(Doodle.pen, tooltip: 'New note', onTap: _addNote),
            DoodleButton(Doodle.plus, tooltip: 'Import a text file', onTap: _import),
          ],
          children: [
            const PageIntro(
              'my files',
              'Notes, imports, receipts and transcripts the assistant can search for you.',
            ),
            TextField(
              controller: _query,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'search every file…',
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(12),
                  child: DoodleIcon(Doodle.search, size: 20, color: p.pencil),
                ),
                suffixIcon: DoodleButton(Doodle.arrow, tooltip: 'Search', size: 20, onTap: _search),
              ),
            ),
            const SizedBox(height: 6),
            Meta(
              semantic
                  ? 'Searching by meaning, with EmbeddingGemma.'
                  : 'Searching by keyword. Download EmbeddingGemma under models to search by meaning.',
            ),
            if (_hits.isNotEmpty) ...[
              const SectionHead('found'),
              for (final h in _hits)
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: Text('${h['title']}', style: context.type.rowTitle)),
                          const SizedBox(width: 8),
                          Caption('${((h['score'] as num) * 100).round()}% match'),
                        ],
                      ),
                      Body('${h['text']}', maxLines: 4),
                    ],
                  ),
                ),
            ],
            SectionHead(
              'documents',
              note: kb.docs.isEmpty ? null : '${kb.docs.length} ${kb.docs.length == 1 ? 'document' : 'documents'}',
            ),
            if (kb.docs.isEmpty)
              const HandEmpty(
                title: 'no files yet',
                body: 'Import text files or write a note. Receipts and voice memos land here too.',
                doodle: Doodle.folder,
              ),
            for (final d in kb.docs)
              ItemRow(
                title: d.title,
                leading: DoodleIcon(switch (d.source) {
                  'expenses' => Doodle.calc,
                  'notes' => Doodle.pen,
                  _ => Doodle.doc,
                }, color: p.pencil),
                caption: '${d.source} · ${d.chunks} passages · ${timeAgo(d.created)}',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => DraggableScrollableSheet(
                    expand: false,
                    builder: (_, c) => ListView(
                      controller: c,
                      padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
                      children: [
                        Text(d.title, style: context.type.contentTitle),
                        Caption('${d.source} · ${timeAgo(d.created)}'),
                        const SizedBox(height: 16),
                        Prose(kb.textOf(d)),
                      ],
                    ),
                  ),
                ),
                trailing: DoodleButton(
                  Doodle.trash,
                  tooltip: 'Remove',
                  size: 20,
                  color: p.pencil,
                  onTap: () => kb.remove(d),
                ),
              ),
          ],
        );
      },
    );
  }
}
