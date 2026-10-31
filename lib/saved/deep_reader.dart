import 'dart:convert';

import 'package:http/http.dart' as http;

import 'link_preview.dart';

/// Reads the whole of a saved link, not just its preview, from each site's own
/// free, official channel:
///
/// * YouTube videos and Shorts: the full description (with chapters) from the
///   watch page, or from the YouTube Data API when the user adds a free key.
/// * GitHub repos: the README, through GitHub's API.
/// * Medium: the article from the author's or publication's official RSS
///   feed, which carries the full text of free (non-member) stories.
/// * Instagram, TikTok, LinkedIn, Threads, X: the post's caption or text, from
///   the oEmbed or preview tags already read by [LinkPreviewer].
///
/// Nothing here logs in, and nothing retries around a refusal.
class DeepReader {
  DeepReader({http.Client? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static const _ua = 'PhoneDots/0.4 (on-device link preview; +https://github.com/Shashank2577/PhoneDots)';
  static const maxBody = 20000;

  /// Fills [p.body] (and missing details) where an official source has more.
  /// Returns the hosts it contacted, for the privacy log.
  Future<List<String>> read(LinkPreview p, {String youtubeKey = ''}) async {
    final contacted = <String>[];
    final uri = Uri.parse(p.url);
    try {
      // A rate limit on the preview means back off from that site entirely.
      if (p.status == 429) return contacted;
      switch (p.platform) {
        case 'youtube':
          final id = youtubeId(uri);
          if (id == null) break;
          if (youtubeKey.isNotEmpty) {
            contacted.add('www.googleapis.com');
            await _youtubeApi(p, id, youtubeKey);
          }
          if (p.body == null) {
            contacted.add('www.youtube.com');
            await _youtubePage(p, id);
          }
        // The API already refused the repo details (rate limit): don't ask it again.
        case 'github' when !LinkPreviewer.isRefusal(p.status):
          contacted.add('api.github.com');
          await _readme(p, uri);
        case 'medium':
          final feed = mediumFeed(uri);
          if (feed != null) {
            contacted.add(feed.host);
            await _mediumRss(p, uri, feed);
          }
        case 'instagram':
          _instagramCaption(p);
        case 'tiktok' || 'linkedin':
          final text = p.platform == 'tiktok' ? p.title : p.description;
          if (p.rich && text != null && text.trim().isNotEmpty) {
            p
              ..body ??= text.trim()
              ..bodyFrom ??= p.platform == 'tiktok' ? 'TikTok embed' : 'LinkedIn preview';
          }
      }
    } catch (_) {
      // Whatever was found before the error stays; the preview is still saved.
    }
    if (p.body != null && p.body!.length > maxBody) p.body = '${p.body!.substring(0, maxBody)}…';
    p.hosts.addAll(contacted);
    return contacted;
  }

  // ── YouTube ──────────────────────────────────────────────────────────────

  static bool isBotCheck(String html) => RegExp(r'"playabilityStatus":\{"status":"LOGIN_REQUIRED"').hasMatch(html);

  static String? youtubeId(Uri u) {
    String? nonEmpty(String? s) => s == null || s.isEmpty ? null : s;
    if (u.host.endsWith('youtu.be')) return nonEmpty(u.pathSegments.firstOrNull);
    final v = nonEmpty(u.queryParameters['v']);
    if (v != null) return v;
    final seg = u.pathSegments;
    if (seg.length >= 2 && const {'shorts', 'live', 'embed'}.contains(seg[0])) return nonEmpty(seg[1]);
    return null;
  }

  Future<void> _youtubeApi(LinkPreview p, String id, String key) async {
    final res = await _client
        .get(
          Uri.https('www.googleapis.com', '/youtube/v3/videos', {
            'part': 'snippet,contentDetails',
            'id': id,
            'key': key,
          }),
        )
        .timeout(timeout);
    if (LinkPreviewer.isRefusal(res.statusCode)) p.refused = true;
    if (res.statusCode != 200) return;
    final items = (jsonDecode(utf8.decode(res.bodyBytes))['items'] as List?) ?? const [];
    if (items.isEmpty) return;
    final sn = Map<String, dynamic>.from(items.first['snippet'] as Map);
    final duration = (items.first['contentDetails'] as Map?)?['duration'] as String?;
    final desc = '${sn['description'] ?? ''}'.trim();
    final tags = (sn['tags'] as List? ?? const []).take(12).join(', ');
    p
      ..title = sn['title'] as String? ?? p.title
      ..author = sn['channelTitle'] as String? ?? p.author
      ..body = [
        if (duration != null) 'Length: ${_isoDuration(duration)}',
        if (tags.isNotEmpty) 'Tags: $tags',
        if (desc.isNotEmpty) desc,
      ].join('\n')
      ..bodyFrom = 'YouTube Data API'
      ..via = 'api';
    if (desc.isNotEmpty) p.description = desc.length > 300 ? '${desc.substring(0, 297)}…' : desc;
  }

  /// The public watch page embeds the full description as JSON.
  Future<void> _youtubePage(LinkPreview p, String id) async {
    final res = await _client
        .get(
          Uri.https('www.youtube.com', '/watch', {'v': id, 'hl': 'en'}),
          headers: {'User-Agent': _ua, 'Accept-Language': 'en'},
        )
        .timeout(timeout);
    if (LinkPreviewer.isRefusal(res.statusCode)) p.refused = true;
    if (res.statusCode != 200) return;
    final html = utf8.decode(res.bodyBytes, allowMalformed: true);
    // A bot check or sign-in wall is YouTube's answer: nothing else may read past it.
    if (isBotCheck(html)) {
      p.refused = true;
      return;
    }
    final body = youtubePageDetails(html);
    if (body == null) return;
    p
      ..body = body.text
      ..bodyFrom = 'YouTube page';
    if (body.description.isNotEmpty) {
      final d = body.description;
      p.description = d.length > 300 ? '${d.substring(0, 297)}…' : d;
    }
  }

  static ({String text, String description})? youtubePageDetails(String html) {
    // A bot check or sign-in wall is YouTube's answer; don't read past it.
    if (isBotCheck(html)) return null;
    String? jsonString(String key) {
      final m = RegExp('"$key":"((?:[^"\\\\]|\\\\.)*)"').firstMatch(html);
      if (m == null) return null;
      try {
        return jsonDecode('"${m.group(1)}"') as String;
      } catch (_) {
        return null;
      }
    }

    final desc = jsonString('shortDescription')?.trim();
    if (desc == null) return null;
    final seconds = int.tryParse(jsonString('lengthSeconds') ?? '');
    final kw = RegExp(r'"keywords":\[((?:"(?:[^"\\]|\\.)*",?)*)\]').firstMatch(html)?.group(1);
    final keywords = kw == null
        ? <String>[]
        : RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(kw).map((m) => m.group(1)!).take(12).toList();
    final text = [
      if (seconds != null) 'Length: ${_clock(seconds)}',
      if (keywords.isNotEmpty) 'Tags: ${keywords.join(', ')}',
      if (desc.isNotEmpty) desc,
    ].join('\n');
    return text.isEmpty ? null : (text: text, description: desc);
  }

  static String _clock(int s) =>
      s >= 3600 ? '${s ~/ 3600}h ${(s % 3600) ~/ 60}m' : (s >= 60 ? '${s ~/ 60}m ${s % 60}s' : '${s}s');

  static String _isoDuration(String iso) {
    final m = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(iso);
    if (m == null) return iso;
    int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
    return _clock(g(1) * 3600 + g(2) * 60 + g(3));
  }

  // ── GitHub ───────────────────────────────────────────────────────────────

  Future<void> _readme(LinkPreview p, Uri uri) async {
    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.length < 2) return;
    final res = await _client
        .get(
          Uri.https('api.github.com', '/repos/${seg[0]}/${seg[1]}/readme'),
          headers: {'Accept': 'application/vnd.github.raw', 'User-Agent': _ua},
        )
        .timeout(timeout);
    if (LinkPreviewer.isRefusal(res.statusCode)) p.refused = true;
    if (res.statusCode != 200) return;
    final md = cleanMarkdown(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (md.isEmpty) return;
    p
      ..body = md
      ..bodyFrom = 'README';
  }

  /// Strips badges, images, HTML and link targets so the model gets prose.
  static String cleanMarkdown(String md) => md
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'\[!\[[^\]]*\]\([^)]*\)\]\([^)]*\)'), '') // linked badges
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '') // images
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  // ── Medium ───────────────────────────────────────────────────────────────

  /// medium.com/@user/… and user.medium.com/… → the author's feed;
  /// medium.com/publication/… → the publication's feed.
  static Uri? mediumFeed(Uri u) {
    final host = u.host.toLowerCase();
    final seg = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (host == 'medium.com' || host == 'www.medium.com') {
      if (seg.isEmpty || seg.first == 'p') return null;
      return Uri.https('medium.com', '/feed/${seg.first}');
    }
    if (host.endsWith('.medium.com')) return Uri.https('medium.com', '/feed/@${host.split('.').first}');
    return null;
  }

  static String? mediumPostId(Uri u) {
    final seg = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.isEmpty) return null;
    return RegExp(r'([0-9a-f]{8,12})$').firstMatch(seg.last)?.group(1);
  }

  Future<void> _mediumRss(LinkPreview p, Uri uri, Uri feed) async {
    final id = mediumPostId(uri);
    if (id == null) return;
    final res = await _client
        .get(feed, headers: {'User-Agent': _ua, 'Accept': 'application/rss+xml, application/xml'})
        .timeout(timeout);
    if (LinkPreviewer.isRefusal(res.statusCode)) p.refused = true;
    if (res.statusCode != 200) return;
    final story = mediumStory(utf8.decode(res.bodyBytes, allowMalformed: true), id);
    if (story == null) return;
    p
      ..title = story.title
      ..author = story.author ?? p.author
      ..imageUrl = p.imageUrl ?? story.image
      ..body = story.text
      ..bodyFrom = 'Medium RSS'
      ..via = 'api'
      ..kind = 'article';
    p.description ??= story.text.length > 300 ? '${story.text.substring(0, 297)}…' : story.text;
  }

  static ({String title, String? author, String text, String? image})? mediumStory(String xml, String id) {
    String? cdata(String item, String tag) {
      final m = RegExp('<$tag[^>]*>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</$tag>').firstMatch(item);
      return m?.group(1)?.trim();
    }

    for (final m in RegExp(r'<item>([\s\S]*?)</item>').allMatches(xml)) {
      final item = m.group(1)!;
      final link = '${cdata(item, 'guid')} ${cdata(item, 'link')}';
      if (!link.contains(id)) continue;
      final html = cdata(item, 'content:encoded') ?? '';
      final image = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(html)?.group(1);
      final text = LinkPreviewer.htmlToText(html);
      if (text.isEmpty) return null;
      return (
        title: LinkPreviewer.decodeEntities(cdata(item, 'title') ?? ''),
        author: cdata(item, 'dc:creator'),
        text: text,
        image: image,
      );
    }
    return null;
  }

  // ── Instagram ────────────────────────────────────────────────────────────

  /// Public posts' preview tags read `123 likes, 4 comments - user on May 1, 2026: "caption".`
  static void _instagramCaption(LinkPreview p) {
    final d = p.description;
    if (!p.rich || d == null) return;
    final m = RegExp(r'^(?:.*?)-\s*([\w.]+)\s+on\s+[^:]+:\s*["“]([\s\S]*)["”]\s*\.?\s*$').firstMatch(d.trim());
    final caption = (m?.group(2) ?? d).trim();
    if (caption.isEmpty) return;
    p
      ..author ??= m?.group(1)
      ..body = caption
      ..bodyFrom = 'Instagram caption';
  }

  void close() => _client.close();
}
