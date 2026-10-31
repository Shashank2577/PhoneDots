import 'package:flutter/foundation.dart';

import '../core/storage/json_store.dart';

class MemoryFact {
  MemoryFact(this.text, this.created);

  final String text;
  final DateTime created;

  Map<String, dynamic> toJson() => {'text': text, 'created': created.toIso8601String()};

  factory MemoryFact.fromJson(Map<String, dynamic> j) =>
      MemoryFact(j['text'] as String, DateTime.parse(j['created'] as String));
}

/// Facts the user explicitly asked the assistant to remember. Fully visible
/// and editable in the Memory screen; nothing is remembered implicitly.
class MemoryStore extends ChangeNotifier {
  MemoryStore(this._store);

  final JsonStore _store;
  static const _key = 'memory';
  final List<MemoryFact> facts = [];

  Future<void> load() async {
    final raw = (await _store.read(_key) as List?) ?? const [];
    facts
      ..clear()
      ..addAll(raw.map((e) => MemoryFact.fromJson(Map<String, dynamic>.from(e as Map))));
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    await _store.write(_key, facts.map((f) => f.toJson()).toList());
  }

  Future<void> add(String text) async {
    final t = text.trim();
    if (t.isEmpty || facts.any((f) => f.text.toLowerCase() == t.toLowerCase())) return;
    facts.insert(0, MemoryFact(t, DateTime.now()));
    await _save();
  }

  Future<void> remove(MemoryFact f) async {
    facts.remove(f);
    await _save();
  }

  Future<void> clear() async {
    facts.clear();
    await _save();
  }

  static Set<String> _terms(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.length > 2 || w.runes.any((c) => c > 0x2e80))
      .toSet();

  List<String> recall(String query, {int limit = 8}) {
    final q = _terms(query);
    final scored = facts.map((f) => (f, _terms(f.text).intersection(q).length)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final hits = scored.where((s) => s.$2 > 0).map((s) => s.$1.text).take(limit).toList();
    // Broad questions ("what do you know about me") get everything recent.
    return hits.isEmpty ? facts.take(limit).map((f) => f.text).toList() : hits;
  }

  Future<bool> forget(String text) async {
    final q = _terms(text);
    MemoryFact? best;
    var bestScore = 0;
    for (final f in facts) {
      final s = _terms(f.text).intersection(q).length;
      if (s > bestScore) {
        best = f;
        bestScore = s;
      }
    }
    if (best == null) return false;
    await remove(best);
    return true;
  }

  /// Compact block injected into the system prompt.
  String get promptBlock => facts.isEmpty ? '' : facts.take(20).map((f) => '- ${f.text}').join('\n');
}
