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

/// Everything the assistant was asked to remember, fully editable.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Remember'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Prefers metric units'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (text != null && context.mounted) await AppScope.services(context).memory.add(text);
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
            'Things you asked PhoneDots to remember. They\'re shared with the model at the start of every chat, and nothing else is kept.',
            doodle: Doodle.heart,
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
              child: Door(
                f.text,
                style: Hand.label.copyWith(fontSize: 24),
                meta: timeAgo(f.created),
                trailing: DoodleButton(
                  Doodle.close,
                  tooltip: 'Forget',
                  size: 20,
                  color: context.pal.redPen,
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
    final title = TextEditingController();
    final body = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('New note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: body,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Text'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && body.text.trim().isNotEmpty && mounted) {
      await AppScope.services(context).knowledge
          .add(title.text.trim().isEmpty ? 'Note' : title.text.trim(), body.text, source: 'notes');
    }
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
              doodle: Doodle.folder,
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
                  ? 'searching by meaning, with EmbeddingGemma'
                  : 'searching by keyword · download EmbeddingGemma under models to search by meaning',
            ),
            if (_hits.isNotEmpty) ...[
              const SectionHead('found'),
              for (final h in _hits)
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${h['title']}'.toLowerCase(),
                              style: Hand.label.copyWith(fontSize: 23, color: p.ink),
                            ),
                          ),
                          Meta('${((h['score'] as num) * 100).round()}% match'),
                        ],
                      ),
                      Meta('${h['text']}', maxLines: 4, color: p.ink),
                    ],
                  ),
                ),
            ],
            SectionHead('documents', note: '${kb.docs.length}'),
            if (kb.docs.isEmpty)
              const HandEmpty(
                title: 'no files yet',
                body: 'Import text files or write a note. Receipts and voice memos land here too.',
                doodle: Doodle.folder,
              ),
            for (final d in kb.docs)
              Door(
                d.title.toLowerCase(),
                style: Hand.label.copyWith(fontSize: 24),
                leading: switch (d.source) {
                  'expenses' => Doodle.calc,
                  'notes' => Doodle.pen,
                  _ => Doodle.doc,
                },
                meta: '${d.source} · ${d.chunks} passages · ${timeAgo(d.created)}',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => DraggableScrollableSheet(
                    expand: false,
                    builder: (_, c) => ListView(
                      controller: c,
                      padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
                      children: [
                        PageIntro(d.title.toLowerCase(), '${d.source} · ${timeAgo(d.created)}'),
                        Body(kb.textOf(d)),
                      ],
                    ),
                  ),
                ),
                trailing: DoodleButton(
                  Doodle.trash,
                  tooltip: 'Remove',
                  size: 20,
                  color: p.redPen,
                  onTap: () => kb.remove(d),
                ),
              ),
          ],
        );
      },
    );
  }
}
