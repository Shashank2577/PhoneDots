import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/util/files.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Everything the assistant was asked to remember, fully editable.
class MemoryScreen extends StatelessWidget {
  const MemoryScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Remember'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Prefers metric units')),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Memory'), actions: [
        IconButton(icon: const Icon(Icons.add_rounded), onPressed: () => _add(context)),
      ]),
      body: ListenableBuilder(
        listenable: memory,
        builder: (context, _) {
          if (memory.facts.isEmpty) {
            return const EmptyState(
              icon: Icons.bookmark_border_rounded,
              title: 'Nothing remembered',
              body: 'Say "remember that…" in chat, or add a fact here. Only facts you ask for are kept.',
            );
          }
          return ListView(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('These are shared with the model at the start of every chat.', style: context.text.bodySmall),
            ),
            for (final f in memory.facts)
              ListTile(
                title: Text(f.text),
                subtitle: Text(timeAgo(f.created)),
                trailing: IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => memory.remove(f)),
              ),
          ]);
        },
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
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 10),
          TextField(controller: body, minLines: 4, maxLines: 8, decoration: const InputDecoration(labelText: 'Text')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && body.text.trim().isNotEmpty && mounted) {
      await AppScope.services(context).knowledge.add(title.text.trim().isEmpty ? 'Note' : title.text.trim(), body.text, source: 'notes');
    }
  }

  Future<void> _import() async {
    final kb = AppScope.services(context).knowledge;
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['txt', 'md', 'csv', 'json', 'srt']);
    if (f == null) return;
    final text = kIsWeb || f.path == null ? utf8.decode(await f.readAsBytes(), allowMalformed: true) : await readTextFile(f.path!);
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
    return Scaffold(
      appBar: AppBar(title: const Text('My files'), actions: [
        IconButton(icon: const Icon(Icons.note_add_outlined), tooltip: 'New note', onPressed: _addNote),
        IconButton(icon: const Icon(Icons.upload_file_rounded), tooltip: 'Import', onPressed: _import),
      ]),
      body: ListenableBuilder(
        listenable: Listenable.merge([kb, s.models]),
        builder: (context, _) {
          final semantic = s.models.isReady(s.settings.embedderId) && !s.isDemo;
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _query,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Search your files',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded, size: 18), onPressed: _search),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(children: [
                Dot(color: semantic ? p.dot : p.warn, size: 6),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    semantic ? 'Semantic search with EmbeddingGemma' : 'Keyword search. Download EmbeddingGemma in Models for meaning-based search.',
                    style: context.text.bodySmall,
                  ),
                ),
              ]),
            ),
            if (_hits.isNotEmpty) ...[
              const SectionLabel('Results'),
              for (final h in _hits)
                Panel(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('${h['title']}', style: context.text.titleMedium)),
                      Text('${((h['score'] as num) * 100).round()}%', style: context.text.bodySmall),
                    ]),
                    const SizedBox(height: 4),
                    Text('${h['text']}', maxLines: 4, overflow: TextOverflow.ellipsis, style: context.text.bodySmall?.copyWith(color: p.ink)),
                  ]),
                ),
            ],
            SectionLabel('Documents · ${kb.docs.length}'),
            if (kb.docs.isEmpty)
              const EmptyState(
                icon: Icons.folder_open_rounded,
                title: 'No files yet',
                body: 'Import text files or notes. Receipts, voice-memo notes and saved transcripts land here too.',
              ),
            for (final d in kb.docs)
              ListTile(
                leading: Icon(
                  switch (d.source) {
                    'expenses' => Icons.receipt_long_outlined,
                    'notes' => Icons.sticky_note_2_outlined,
                    _ => Icons.description_outlined,
                  },
                  size: 20,
                ),
                title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${d.source} · ${d.chunks} passages · ${timeAgo(d.created)}'),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => DraggableScrollableSheet(
                    expand: false,
                    builder: (_, c) => ListView(controller: c, padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
                      Text(d.title, style: context.text.titleLarge),
                      const SizedBox(height: 12),
                      SelectableText(kb.textOf(d), style: context.text.bodyMedium),
                    ]),
                  ),
                ),
                trailing: IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => kb.remove(d)),
              ),
          ]);
        },
      ),
    );
  }
}
