import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/runtime/engines.dart';
import '../core/storage/json_store.dart';

class KnowledgeDoc {
  KnowledgeDoc({required this.id, required this.title, required this.source, required this.created, required this.chunks});

  final String id;
  final String title;
  final String source;
  final DateTime created;
  final int chunks;

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'source': source, 'created': created.toIso8601String(), 'chunks': chunks};

  factory KnowledgeDoc.fromJson(Map<String, dynamic> j) => KnowledgeDoc(
        id: j['id'] as String,
        title: j['title'] as String,
        source: j['source'] as String,
        created: DateTime.parse(j['created'] as String),
        chunks: j['chunks'] as int,
      );
}

class _Chunk {
  _Chunk(this.docId, this.title, this.text, this.vector);

  final String docId;
  final String title;
  final String text;
  List<double> vector;

  Map<String, dynamic> toJson() => {'d': docId, 't': title, 'x': text, 'v': vector.map((e) => double.parse(e.toStringAsFixed(4))).toList()};

  factory _Chunk.fromJson(Map<String, dynamic> j) => _Chunk(
        j['d'] as String,
        j['t'] as String,
        j['x'] as String,
        (j['v'] as List).map((e) => (e as num).toDouble()).toList(),
      );
}

/// On-device retrieval index. Vectors come from EmbeddingGemma when it is
/// downloaded, otherwise from the lexical fallback; switching re-embeds.
class KnowledgeBase extends ChangeNotifier {
  KnowledgeBase({required this.store, required this.embedder});

  final JsonStore store;

  /// Resolves the best available embedder at call time.
  final Future<Embedder> Function() embedder;

  static const _key = 'knowledge';
  final List<KnowledgeDoc> docs = [];
  final List<_Chunk> _chunks = [];
  String _indexedWith = '';

  Future<void> load() async {
    final j = await store.read(_key) as Map?;
    if (j == null) return;
    docs.addAll((j['docs'] as List).map((d) => KnowledgeDoc.fromJson(Map<String, dynamic>.from(d as Map))));
    _chunks.addAll((j['chunks'] as List).map((c) => _Chunk.fromJson(Map<String, dynamic>.from(c as Map))));
    _indexedWith = j['embedder'] as String? ?? '';
    notifyListeners();
  }

  Future<void> _save() => store.write(_key, {
        'embedder': _indexedWith,
        'docs': docs.map((d) => d.toJson()).toList(),
        'chunks': _chunks.map((c) => c.toJson()).toList(),
      });

  String _embedderKey(Embedder e) => '${e.runtimeType}:${e.dimensions}';

  static List<String> chunk(String text, {int words = 120, int overlap = 20}) {
    final w = text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (w.length <= words) return [w.join(' ')];
    final out = <String>[];
    for (var i = 0; i < w.length; i += words - overlap) {
      out.add(w.sublist(i, min(i + words, w.length)).join(' '));
      if (i + words >= w.length) break;
    }
    return out;
  }

  Future<int> add(String title, String text, {String source = 'chat'}) async {
    final e = await embedder();
    await _reindexIfNeeded(e);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final parts = chunk(text);
    for (final p in parts) {
      _chunks.add(_Chunk(id, title, p, await e.embed('$title\n$p')));
    }
    docs.insert(0, KnowledgeDoc(id: id, title: title, source: source, created: DateTime.now(), chunks: parts.length));
    notifyListeners();
    await _save();
    return parts.length;
  }

  Future<void> remove(KnowledgeDoc doc) async {
    docs.removeWhere((d) => d.id == doc.id);
    _chunks.removeWhere((c) => c.docId == doc.id);
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    docs.clear();
    _chunks.clear();
    notifyListeners();
    await store.delete(_key);
  }

  String textOf(KnowledgeDoc doc) => _chunks.where((c) => c.docId == doc.id).map((c) => c.text).join('\n\n');

  Future<void> _reindexIfNeeded(Embedder e) async {
    final key = _embedderKey(e);
    if (_indexedWith == key) return;
    for (final c in _chunks) {
      c.vector = await e.embed('${c.title}\n${c.text}');
    }
    _indexedWith = key;
    if (_chunks.isNotEmpty) await _save();
  }

  static double cosine(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return na == 0 || nb == 0 ? 0 : dot / (sqrt(na) * sqrt(nb));
  }

  /// Hybrid ranking: vector similarity plus a small exact-keyword bonus.
  Future<List<Map<String, dynamic>>> search(String query, {int limit = 5}) async {
    if (_chunks.isEmpty) return const [];
    final e = await embedder();
    await _reindexIfNeeded(e);
    final q = await e.embed(query);
    final terms = query.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((t) => t.length > 3).toSet();
    final scored = _chunks.map((c) {
      final lower = c.text.toLowerCase();
      final bonus = terms.isEmpty ? 0 : terms.where(lower.contains).length / terms.length * 0.15;
      return (c, cosine(q, c.vector) + bonus);
    }).where((x) => x.$2 > 0.12).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final s in scored.take(limit)) {'title': s.$1.title, 'text': s.$1.text, 'score': min(1.0, s.$2)},
    ];
  }
}
