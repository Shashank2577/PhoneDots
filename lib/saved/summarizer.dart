import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../core/ledger.dart';
import '../core/settings.dart';
import '../core/util/files.dart';
import 'link_preview.dart';
import 'saved_store.dart';
import 'web_reader.dart';

typedef AskModel = Future<String> Function({required String system, required String prompt, List<String> imagePaths});

/// Thrown by [AskModel] when no Gemma model is downloaded yet.
class NoModelError implements Exception {
  const NoModelError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns a share into a saved, summarised item.
///
/// Gathering is free and cheapest-first: the text the sharing app sent, the
/// site's official embed or preview tags, the cover image (looked at by Gemma
/// on the phone), an optional free web reader, and a transcript for shared
/// audio or video files. The summary itself is always written on the phone.
class Summarizer {
  Summarizer({
    required this.store,
    required this.links,
    required this.reader,
    required this.settings,
    required this.ledger,
    required this.ask,
    required this.canSee,
    this.transcribe,
    this.filesDir,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final SavedStore store;
  final LinkPreviewer links;
  final WebReader reader;
  final AppSettings settings;
  final Ledger ledger;
  final AskModel ask;

  /// Whether the loaded Gemma can look at images (false in the demo engine).
  final bool Function() canSee;
  final Future<String?> Function(String path)? transcribe;
  final String? filesDir;
  final http.Client _client;

  static const _uuid = Uuid();
  Future<void> _queue = Future.value();

  /// One item at a time, so summaries never fight the chat for the model.
  Future<void> _enqueue(SavedItem item) {
    final next = _queue.then((_) => process(item)).catchError((_) {});
    _queue = next;
    return next;
  }

  /// Saves what another app shared and starts reading it. Returns at once.
  Future<SavedItem> addShare({String text = '', String? subject, List<Map<String, String>> files = const []}) async {
    final urls = LinkPreviewer.findUrls('$text ${subject ?? ''}', max: 1);
    final url = urls.isEmpty ? null : urls.first;
    var caption = text;
    for (final m in LinkPreviewer.urlPattern.allMatches(text).toList().reversed) {
      caption = caption.replaceRange(m.start, m.end, '');
    }
    caption = caption.replaceAll(RegExp(r'\s+'), ' ').trim();
    final image = files.where((f) => f['kind'] == 'image').map((f) => f['path']).firstOrNull;
    final item = SavedItem(
      id: _uuid.v4(),
      created: DateTime.now(),
      sharedText: caption,
      subject: subject?.trim().isEmpty ?? true ? null : subject!.trim(),
      url: url,
      platform: url == null ? (image != null ? 'screenshot' : 'file') : LinkPreviewer.platformOf(Uri.parse(url)),
      kind: url == null
          ? (image != null ? 'image' : (files.isNotEmpty ? files.first['kind'] ?? 'file' : 'note'))
          : 'link',
      imagePath: image,
      files: files,
    );
    await store.add(item);
    if (settings.autoSummarise) {
      unawaited(_enqueue(item));
    } else {
      item.status = SavedStatus.needsModel;
      await store.save();
    }
    return item;
  }

  Future<void> resummarise(SavedItem item) => _enqueue(item);

  Future<void> process(SavedItem item) async {
    item
      ..status = SavedStatus.reading
      ..error = null
      ..sources = [];
    await store.save();
    if (item.sharedText.isNotEmpty) item.sources.add('caption');
    if (item.subject != null) item.sources.add('share title');

    String? pageText;
    final url = item.url;
    if (url != null && settings.readLinks) {
      final host = Uri.tryParse(url)?.host ?? url;
      final p = await links.preview(url);
      unawaited(ledger.record('link', 'Read the preview of $host', network: true));
      item
        ..url = p.url
        ..platform = p.platform
        ..kind = p.kind
        ..author = p.author ?? item.author
        ..description = p.description ?? item.description
        ..imageUrl = p.imageUrl ?? item.imageUrl;
      if (p.rich || item.title == null) item.title = p.rich ? p.title : (item.subject ?? p.title);
      if (p.rich) {
        item.sources.add(switch (p.via) {
          'oembed' => 'official embed',
          'api' => 'GitHub API',
          _ => 'page preview',
        });
      }
      // Only for pages the site served openly but described thinly. A refusal,
      // bot check or login wall is the site's answer; the reader is not a way round it.
      if (settings.webReader && p.servedOpenly && (item.description ?? '').length < 200) {
        pageText = await reader.read(p.url);
        unawaited(ledger.record('link', 'Asked ${WebReader.name} to read $host', network: true));
        if (pageText != null) item.sources.add(WebReader.name);
      }
    } else if (url != null) {
      item.title ??= item.subject;
    }

    if (canSee() && item.imagePath == null && item.imageUrl != null) {
      item.imagePath = await _downloadCover(item);
      if (item.imagePath != null) item.sources.add('cover image');
    } else if (item.imagePath != null && item.url == null) {
      item.sources.add('screenshot');
    }

    final transcripts = <String>[];
    for (final f in item.files.where((f) => f['kind'] == 'audio')) {
      final t = await transcribe?.call(f['path']!);
      if (t != null && t.trim().isNotEmpty) transcripts.add(t.trim());
    }
    if (transcripts.isNotEmpty) item.sources.add('transcript');

    item.status = SavedStatus.summarising;
    await store.save();
    try {
      final see = canSee() && item.imagePath != null;
      final raw = await ask(
        system: systemPrompt({...store.collections, ...SavedStore.defaultCollections}.take(16).toList()),
        prompt: material(item, pageText: pageText, transcript: transcripts.join('\n'), image: see),
        imagePaths: see ? [item.imagePath!] : const [],
      );
      apply(item, raw);
      item.status = SavedStatus.done;
      unawaited(ledger.record('saved', 'Summarised "${item.displayTitle}" on this phone'));
    } on NoModelError catch (e) {
      item
        ..status = SavedStatus.needsModel
        ..error = e.message;
    } catch (e) {
      item
        ..status = SavedStatus.failed
        ..error = '$e';
    }
    await store.save();
  }

  Future<String?> _downloadCover(SavedItem item) async {
    try {
      final uri = Uri.parse(item.imageUrl!);
      if (uri.scheme != 'https') return null;
      final res = await _client.get(uri).timeout(const Duration(seconds: 15));
      unawaited(ledger.record('link', 'Downloaded the cover image from ${uri.host}', network: true));
      final type = res.headers['content-type'] ?? '';
      if (res.statusCode != 200 || !type.startsWith('image/') || res.bodyBytes.length > 6 * 1024 * 1024) return null;
      final ext = type.contains('png') ? 'png' : (type.contains('webp') ? 'webp' : 'jpg');
      return await writeBytesFile(filesDir, 'cover-${item.id}.$ext', res.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  // ── prompt ───────────────────────────────────────────────────────────────

  static String systemPrompt(List<String> collections) =>
      'You file things the user saved from other apps. Write a short summary of the saved item from the material '
      'given, and reply with JSON only, no other text:\n'
      '{"title": "short title, max 8 words", "summary": "one or two plain sentences: what it is and why it is useful", '
      '"points": ["up to 4 key takeaways, steps or facts"], "collection": "one word", "tags": ["up to 4 lowercase tags"]}\n'
      'Pick the collection from: ${collections.join(', ')}; invent a better one-word name only if none fits.\n'
      'Use only the material. For a video or reel you only have its caption, cover and creator: summarise those and '
      'do not describe scenes you cannot see. If the material is thin, say plainly what it is. Never invent details.';

  static String material(SavedItem i, {String? pageText, String transcript = '', bool image = false}) {
    String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
    final b = StringBuffer();
    if (i.url != null) b.writeln('Link: ${i.url} (${i.platform} ${i.kind})');
    if (i.title != null) b.writeln('Title: ${i.title}');
    if (i.subject != null && i.subject != i.title) b.writeln('Shared with the title: ${i.subject}');
    if (i.author != null) b.writeln('Creator: ${i.author}');
    if (i.sharedText.isNotEmpty) b.writeln('Text shared with it: ${clip(i.sharedText, 1500)}');
    if ((i.description ?? '').isNotEmpty) b.writeln('Caption / description: ${clip(i.description!, 2000)}');
    if (pageText != null) b.writeln('Page text:\n${clip(pageText, 4000)}');
    if (transcript.isNotEmpty) b.writeln('Transcript:\n${clip(transcript, 3000)}');
    for (final f in i.files.where((f) => f['kind'] != 'image')) {
      b.writeln('Shared file: ${f['name']}');
    }
    if (image)
      b.writeln(
        i.url == null
            ? 'The attached image is the screenshot the user saved.'
            : 'The attached image is the post\'s cover.',
      );
    if (b.isEmpty) b.writeln('(Nothing but the share itself.)');
    return b.toString().trim();
  }

  /// Fills the item from the model's reply, tolerating non-JSON answers.
  static void apply(SavedItem item, String raw) {
    final j = parseJson(raw);
    if (j != null) {
      final title = '${j['title'] ?? ''}'.trim();
      if (title.isNotEmpty && (item.title == null || item.url == null || item.sources.isEmpty)) item.title = title;
      item
        ..summary = '${j['summary'] ?? ''}'.trim()
        ..points = _strings(j['points'], 4)
        ..tags = _strings(j['tags'], 4).map((t) => t.toLowerCase().replaceFirst('#', '')).toList()
        ..collection = _collection('${j['collection'] ?? ''}');
      if (item.summary!.isEmpty) item.summary = null;
      return;
    }
    final lines = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final bullets = lines
        .where((l) => RegExp(r'^([-*•]|\d+[.)])\s+').hasMatch(l))
        .map((l) => l.replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s+'), ''))
        .toList();
    final prose = lines.where((l) => !RegExp(r'^([-*•]|\d+[.)])\s+').hasMatch(l)).join(' ');
    item
      ..summary = prose.isNotEmpty ? prose : (bullets.isNotEmpty ? bullets.first : null)
      ..points = bullets.take(4).toList()
      ..collection ??= 'other';
  }

  static Map<String, dynamic>? parseJson(String raw) {
    final a = raw.indexOf('{');
    final b = raw.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final j = jsonDecode(raw.substring(a, b + 1));
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static List<String> _strings(Object? v, int max) => v is List
      ? v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).take(max).toList()
      : (v is String && v.trim().isNotEmpty ? [v.trim()] : <String>[]);

  static String _collection(String c) {
    final s = c.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 &-]'), '').trim();
    if (s.isEmpty) return 'other';
    return s.length > 20 ? s.substring(0, 20) : s;
  }

  void close() => _client.close();
}
