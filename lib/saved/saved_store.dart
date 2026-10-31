import 'package:flutter/foundation.dart';

import '../core/storage/json_store.dart';

enum SavedStatus { reading, summarising, done, needsModel, failed }

/// Something the user shared into PhoneDots: a link, a screenshot, a clip.
class SavedItem {
  SavedItem({
    required this.id,
    required this.created,
    this.sharedText = '',
    this.subject,
    this.url,
    this.platform = 'web',
    this.kind = 'link',
    this.title,
    this.author,
    this.description,
    this.imageUrl,
    this.imagePath,
    List<Map<String, String>>? files,
    this.summary,
    List<String>? points,
    List<String>? tags,
    this.collection,
    this.status = SavedStatus.reading,
    this.error,
    List<String>? sources,
  }) : files = files ?? [],
       points = points ?? [],
       tags = tags ?? [],
       sources = sources ?? [];

  final String id;
  final DateTime created;

  /// What the sharing app sent alongside the link (often the caption).
  String sharedText;

  /// The share sheet's subject line (YouTube puts the video title here).
  String? subject;
  String? url;
  String platform;
  String kind;
  String? title;
  String? author;
  String? description;
  String? imageUrl;

  /// Local copy of the cover image or the shared screenshot.
  String? imagePath;

  /// Shared files: {path, name, kind}.
  final List<Map<String, String>> files;

  String? summary;
  List<String> points;
  List<String> tags;
  String? collection;
  SavedStatus status;
  String? error;

  /// Where the details came from, shown on the item ("caption", "Jina Reader"…).
  List<String> sources;

  bool get busy => status == SavedStatus.reading || status == SavedStatus.summarising;

  String get displayTitle {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    if (files.isNotEmpty) return files.first['name'] ?? 'shared file';
    return url ?? (sharedText.isEmpty ? 'saved item' : sharedText);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'created': created.toIso8601String(),
    'sharedText': sharedText,
    'subject': subject,
    'url': url,
    'platform': platform,
    'kind': kind,
    'title': title,
    'author': author,
    'description': description,
    'imageUrl': imageUrl,
    'imagePath': imagePath,
    'files': files,
    'summary': summary,
    'points': points,
    'tags': tags,
    'collection': collection,
    // Work interrupted by the app closing resumes as "needs a summary".
    'status': busy ? SavedStatus.needsModel.name : status.name,
    'error': error,
    'sources': sources,
  };

  factory SavedItem.fromJson(Map<String, dynamic> j) => SavedItem(
    id: j['id'] as String,
    created: DateTime.tryParse('${j['created']}') ?? DateTime.now(),
    sharedText: j['sharedText'] as String? ?? '',
    subject: j['subject'] as String?,
    url: j['url'] as String?,
    platform: j['platform'] as String? ?? 'web',
    kind: j['kind'] as String? ?? 'link',
    title: j['title'] as String?,
    author: j['author'] as String?,
    description: j['description'] as String?,
    imageUrl: j['imageUrl'] as String?,
    imagePath: j['imagePath'] as String?,
    files: [for (final f in (j['files'] as List? ?? const [])) Map<String, String>.from(f as Map)],
    summary: j['summary'] as String?,
    points: (j['points'] as List? ?? const []).cast<String>(),
    tags: (j['tags'] as List? ?? const []).cast<String>(),
    collection: j['collection'] as String?,
    status: SavedStatus.values.asNameMap()[j['status']] ?? SavedStatus.done,
    error: j['error'] as String?,
    sources: (j['sources'] as List? ?? const []).cast<String>(),
  );
}

/// Everything saved, newest first, kept on the phone.
class SavedStore extends ChangeNotifier {
  SavedStore(this._store);

  final JsonStore _store;
  static const _key = 'saved';
  final List<SavedItem> items = [];

  static const defaultCollections = [
    'recipes',
    'travel',
    'shopping',
    'learning',
    'tech',
    'fitness',
    'ideas',
    'funny',
    'music',
    'news',
  ];

  Future<void> load() async {
    final list = (await _store.read(_key) as List?) ?? const [];
    items
      ..clear()
      ..addAll(list.map((m) => SavedItem.fromJson(Map<String, dynamic>.from(m as Map))));
    notifyListeners();
  }

  SavedItem? byId(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Collections in use, most used first.
  List<String> get collections {
    final counts = <String, int>{};
    for (final i in items) {
      final c = i.collection;
      if (c != null && c.isNotEmpty) counts[c] = (counts[c] ?? 0) + 1;
    }
    return counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  List<SavedItem> search(String query, {String? collection}) {
    final q = query.trim().toLowerCase();
    return items.where((i) {
      if (collection != null && i.collection != collection) return false;
      if (q.isEmpty) return true;
      final hay = [
        i.title,
        i.summary,
        i.description,
        i.author,
        i.sharedText,
        i.url,
        ...i.points,
        ...i.tags,
      ].whereType<String>().join(' ').toLowerCase();
      return q.split(RegExp(r'\s+')).every(hay.contains);
    }).toList();
  }

  Future<void> add(SavedItem item) async {
    items.insert(0, item);
    await save();
  }

  Future<void> remove(SavedItem item) async {
    items.removeWhere((i) => i.id == item.id);
    await save();
  }

  Future<void> clear() async {
    items.clear();
    await save();
  }

  /// Persists and tells listeners after an item changed in place.
  Future<void> save() async {
    notifyListeners();
    await _store.write(_key, items.map((i) => i.toJson()).toList());
  }
}
