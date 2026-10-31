import 'dart:convert';

import 'package:http/http.dart' as http;

/// What PhoneDots could learn about a shared link, and how.
class LinkPreview {
  LinkPreview({
    required this.url,
    required this.platform,
    this.title,
    this.description,
    this.author,
    this.imageUrl,
    this.kind = 'link',
    this.via = 'url',
    this.status,
  });

  /// Cleaned URL (tracking parameters removed, short links expanded).
  final String url;

  /// youtube | tiktok | instagram | threads | linkedin | github | medium | x | web
  final String platform;
  String? title;
  String? description;
  String? author;
  String? imageUrl;

  /// video | post | profile | repo | article | link
  String kind;

  /// How the details were found: oembed | api | meta | url (slug fallback).
  String via;

  /// HTTP status of the last request, for diagnostics.
  int? status;

  /// The site answered with a login wall or bot check instead of the page.
  bool walled = false;

  /// The site itself served the page or its official embed normally, so
  /// reading more of it respects the site's choice. False after a refusal
  /// (401/403/429), a bot check or a login wall.
  bool get servedOpenly => status == 200 && !walled;

  /// True when we got real metadata, not just the URL-derived fallback.
  bool get rich => via != 'url';

  Map<String, dynamic> toJson() => {
    'url': url,
    'platform': platform,
    'title': title,
    'description': description,
    'author': author,
    'imageUrl': imageUrl,
    'kind': kind,
    'via': via,
  };
}

/// Fetches previews for shared links. Each request goes straight from the
/// phone to the site (or its official oEmbed/API endpoint); nothing passes
/// through a PhoneDots server. Callers log every fetch in the privacy ledger.
class LinkPreviewer {
  LinkPreviewer({http.Client? client, this.timeout = const Duration(seconds: 12)}) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// PhoneDots identifies itself honestly. It reads only the preview tags a
  /// page publishes, and never retries around login walls or bot checks.
  static const _ua = 'PhoneDots/0.4 (on-device link preview; +https://github.com/Shashank2577/PhoneDots)';

  static const _tracking = {
    'si', 'cplk', 'igsh', 'igshid', 'xmt', 'fbclid', 'gclid', 'ref', 'ref_src', 'feature', 'source', 'utm_source', //
    'utm_medium',
    'utm_campaign',
    'utm_term',
    'utm_content',
    'trk',
    'lipi',
    'rcm',
    'is_from_webapp',
    'sender_device',
    'mibextid',
  };

  static final urlPattern = RegExp(
    r'''(?:https?://|www\.)[^\s<>"']+|\b(?:youtu\.be|(?:[a-z]+\.)?(?:youtube|tiktok|instagram|threads|linkedin|github|medium|x|twitter)\.(?:com|net))/[^\s<>"']*''',
    caseSensitive: false,
  );

  /// Every link in [text], cleaned and de-duplicated, in order.
  static List<String> findUrls(String text, {int max = 3}) => urlPattern
      .allMatches(text)
      .map((m) => clean(m.group(0)!.replaceAll(RegExp(r'[).,!?]+$'), '')).toString())
      .toSet()
      .take(max)
      .toList();

  /// Removes tracking parameters and fragments; keeps what identifies the content (e.g. YouTube's v).
  static Uri clean(String raw) {
    var u = Uri.parse(raw.trim());
    if (!u.hasScheme) u = Uri.parse('https://${raw.trim()}');
    final q = Map.of(u.queryParameters)..removeWhere((k, _) => _tracking.contains(k.toLowerCase()));
    // Uri.replace(queryParameters: null) keeps the old query, so rebuild instead.
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path,
      queryParameters: q.isEmpty ? null : q,
    );
  }

  static String platformOf(Uri u) {
    final h = u.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|mobile)\.'), '');
    if (h == 'youtu.be' || h.endsWith('youtube.com')) return 'youtube';
    if (h.endsWith('tiktok.com')) return 'tiktok';
    if (h.endsWith('instagram.com')) return 'instagram';
    if (h.endsWith('threads.net') || h.endsWith('threads.com')) return 'threads';
    if (h.endsWith('linkedin.com') || h == 'lnkd.in') return 'linkedin';
    if (h == 'github.com') return 'github';
    if (h == 'medium.com' || h.endsWith('.medium.com')) return 'medium';
    if (h == 'x.com' || h == 'twitter.com') return 'x';
    return 'web';
  }

  Future<LinkPreview> preview(String raw) async {
    var uri = clean(raw);
    if (_isShortLink(uri)) uri = await _expand(uri);
    final platform = platformOf(uri);
    final p = LinkPreview(url: uri.toString(), platform: platform, kind: _kindFromPath(platform, uri));
    try {
      switch (platform) {
        case 'youtube':
          await _oembed(p, Uri.https('www.youtube.com', '/oembed', {'url': p.url, 'format': 'json'}));
        case 'tiktok':
          await _oembed(p, Uri.https('www.tiktok.com', '/oembed', {'url': p.url}));
        case 'github':
          await _github(p, uri);
      }
      if (!p.rich) await _meta(p, uri);
    } catch (_) {
      // Network or parse problems fall through to the URL-derived title below.
    }
    if (p.title == null || p.title!.trim().isEmpty) {
      p
        ..title = _titleFromUrl(uri, platform, p.kind)
        ..via = 'url';
    }
    p.title = _tidyTitle(p.title!, platform);
    return p;
  }

  // ── sources ──────────────────────────────────────────────────────────────

  Future<void> _oembed(LinkPreview p, Uri endpoint) async {
    final res = await _client.get(endpoint, headers: {'User-Agent': _ua}).timeout(timeout);
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    p
      ..author = j['author_name'] as String? ?? p.author
      ..imageUrl = j['thumbnail_url'] as String? ?? p.imageUrl;
    // Some embeds answer without a title (e.g. TikTok videos with embedding limited).
    final title = (j['title'] as String?)?.trim();
    if (title != null && title.isNotEmpty) {
      p
        ..title = title
        ..via = 'oembed';
    }
  }

  Future<void> _github(LinkPreview p, Uri uri) async {
    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.length < 2) return;
    final res = await _client
        .get(
          Uri.https('api.github.com', '/repos/${seg[0]}/${seg[1]}'),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': _ua},
        )
        .timeout(timeout);
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final stars = j['stargazers_count'];
    p
      ..title = j['full_name'] as String?
      ..description = [
        j['description'],
        if (j['language'] != null) j['language'],
        if (stars != null) '★ $stars',
      ].whereType<Object>().join(' · ')
      ..author = (j['owner'] as Map?)?['login'] as String?
      ..imageUrl = 'https://opengraph.githubassets.com/1/${seg[0]}/${seg[1]}'
      ..kind = 'repo'
      ..via = 'api';
  }

  Future<void> _meta(LinkPreview p, Uri uri) async {
    final res = await _client
        .get(uri, headers: {'User-Agent': _ua, 'Accept': 'text/html,application/xhtml+xml', 'Accept-Language': 'en'})
        .timeout(timeout);
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final bytes = res.bodyBytes.length > 2000000 ? res.bodyBytes.sublist(0, 2000000) : res.bodyBytes;
    final m = parseMeta(utf8.decode(bytes, allowMalformed: true));
    final title = m['og:title'] ?? m['twitter:title'] ?? m['title'];
    if (title == null || _isGenericTitle(title, p.platform)) {
      p.walled = true;
      return;
    }
    p
      ..title = title
      ..description = m['og:description'] ?? m['twitter:description'] ?? m['description']
      ..imageUrl = m['og:image'] ?? m['twitter:image']
      ..author = p.author ?? m['author'] ?? m['article:author']
      ..via = 'meta';
  }

  // ── parsing ──────────────────────────────────────────────────────────────

  /// Pulls Open Graph, Twitter and basic meta tags out of HTML.
  static Map<String, String> parseMeta(String html) {
    final out = <String, String>{};
    final head = html.length > 400000 ? html.substring(0, 400000) : html;
    for (final tag in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(head)) {
      final t = tag.group(0)!;
      String? attr(String name) => RegExp(
        '$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')',
        caseSensitive: false,
      ).firstMatch(t)?.let((m) => m.group(2) ?? m.group(3));
      final key = (attr('property') ?? attr('name') ?? attr('itemprop'))?.toLowerCase();
      final value = attr('content');
      if (key == null || value == null || value.trim().isEmpty) continue;
      out.putIfAbsent(key, () => decodeEntities(value.trim()));
    }
    final title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(head)?.group(1);
    if (title != null && title.trim().isNotEmpty) out.putIfAbsent('title', () => decodeEntities(title.trim()));
    return out;
  }

  static String decodeEntities(String s) {
    final once = _decode(s);
    return once.contains('&') ? _decode(once) : once;
  }

  static String _decode(String s) => s
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  /// Login walls and error pages return a title but not a useful one.
  static bool _isGenericTitle(String t, String platform) {
    final l = t.toLowerCase().trim();
    const generic = {
      'instagram',
      'login • instagram',
      'tiktok - make your day',
      'linkedin',
      'sign up | linkedin',
      'threads',
      'youtube',
      'just a moment...',
      'attention required! | cloudflare',
      'medium',
      'x',
      'access denied',
      'page not found',
    };
    return generic.contains(l) ||
        l.startsWith('log in') ||
        l.startsWith('sign in') ||
        l.endsWith('• log in') ||
        l.endsWith('| log in');
  }

  static String _tidyTitle(String t, String platform) {
    var s = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final suffix in [' - YouTube', ' | LinkedIn', ' • Instagram', ' | Medium', ' • Threads', ' | TikTok']) {
      if (s.endsWith(suffix)) s = s.substring(0, s.length - suffix.length);
    }
    return s.length > 160 ? '${s.substring(0, 157)}…' : s;
  }

  // ── url helpers ──────────────────────────────────────────────────────────

  static bool _isShortLink(Uri u) => const {
    'vm.tiktok.com',
    'vt.tiktok.com',
    'lnkd.in',
    't.co',
    'bit.ly',
    'link.medium.com',
  }.contains(u.host.toLowerCase());

  /// Follows a short link's redirects without downloading the page.
  Future<Uri> _expand(Uri u) async {
    var current = u;
    for (var i = 0; i < 5; i++) {
      final req = http.Request('HEAD', current)
        ..followRedirects = false
        ..headers['User-Agent'] = _ua;
      final res = await _client.send(req).timeout(timeout);
      final loc = res.headers['location'];
      if (res.statusCode < 300 || res.statusCode >= 400 || loc == null) break;
      current = clean(current.resolve(loc).toString());
    }
    return current;
  }

  static String _kindFromPath(String platform, Uri u) {
    final path = u.path.toLowerCase();
    return switch (platform) {
      'youtube' || 'tiktok' => path.contains('/@') && !path.contains('/video/') ? 'profile' : 'video',
      'instagram' => path.contains('/reel') ? 'video' : (path.contains('/p/') ? 'post' : 'profile'),
      'threads' => path.contains('/post/') ? 'post' : 'profile',
      'linkedin' =>
        path.contains('/posts/') || path.contains('/feed/update/')
            ? 'post'
            : (path.contains('/pulse/') ? 'article' : 'profile'),
      'github' => 'repo',
      'medium' => 'article',
      _ => 'link',
    };
  }

  /// A readable title from the URL alone, so a save never ends up nameless.
  static String _titleFromUrl(Uri u, [String platform = 'web', String kind = 'link']) {
    final seg = u.pathSegments.where((s) => s.isNotEmpty).toList();
    final host = u.host.replaceFirst(RegExp(r'^www\.'), '');
    if (seg.isEmpty) return host;
    final handle = seg.firstWhere((s) => s.startsWith('@'), orElse: () => '');
    // Social posts have opaque ids; name them by kind and author instead.
    if (const {'tiktok', 'instagram', 'threads', 'x'}.contains(platform)) {
      final name = handle.isNotEmpty ? handle : (kind == 'profile' ? '@${seg.first}' : '');
      final label = const {'tiktok': 'TikTok', 'instagram': 'Instagram', 'threads': 'Threads', 'x': 'X'}[platform]!;
      if (kind == 'profile') return '$name on $label';
      return name.isEmpty ? '$label $kind' : '$label $kind by $name';
    }
    var last = Uri.decodeComponent(seg.last).replaceAll(RegExp(r'\.(html?|php)$'), '');
    // Medium-style slugs end in a hex id: "software-2-0-a64152b37c35".
    last = last.replaceFirst(RegExp(r'-[0-9a-f]{8,12}$'), '');
    if (seg.length >= 2 && RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(last) && !last.contains('-')) {
      return '${seg.first.startsWith('@') ? seg.first : host} · ${seg[seg.length - 2]}';
    }
    final words = last.split(RegExp(r'[-_+]')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return host;
    final title = words.join(' ');
    final pretty = '${title[0].toUpperCase()}${title.substring(1)}';
    return handle.isEmpty ? pretty : '$pretty · $handle';
  }

  void close() => _client.close();
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
