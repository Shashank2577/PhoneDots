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

  /// The whole readable text when an official source has it: a video's full
  /// description, a repo's README, a free article, a post's text.
  String? body;

  /// Where [body] came from, e.g. "YouTube page", "README", "Medium RSS".
  String? bodyFrom;

  /// An official endpoint refused (401/403/429) or showed a bot check while
  /// reading the full text. Reading more of it any other way is not allowed.
  bool refused = false;

  /// Every host PhoneDots contacted for this link, for the privacy log.
  final Set<String> hosts = {};

  /// The site answered with a login wall or bot check instead of the page.
  bool walled = false;

  /// The site itself served the page or its official embed normally, so
  /// reading more of it respects the site's choice. False after a refusal
  /// (401/403/429), a bot check or a login wall.
  bool get servedOpenly => status == 200 && !walled && !refused;

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
    if (body != null) 'body': body,
    if (bodyFrom != null) 'bodyFrom': bodyFrom,
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
    r'''(?<![\w./:@-])(?:https?://|www\.)[^\s<>"']+|\b(?:youtu\.be|(?:[a-z]+\.)?(?:youtube|tiktok|instagram|threads|linkedin|github|medium|x|twitter)\.(?:com|net))/[^\s<>"']*''',
    caseSensitive: false,
  );

  static const _trailing = '.,!?;:]}"\'”’»«。、…';
  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Drops punctuation, closing quotes and emoji glued to the end of a link.
  /// A closing parenthesis stays when the link itself opened one (Wikipedia).
  static String trimUrl(String s) {
    var u = s;
    while (u.isNotEmpty) {
      final last = String.fromCharCode(u.runes.last);
      final cut = u.substring(0, u.length - last.length);
      if (_trailing.contains(last)) {
        u = cut;
      } else if (last == ')') {
        if ('('.allMatches(u).length >= ')'.allMatches(u).length) break;
        u = cut;
      } else if (u.runes.last > 0x7f && !_letterOrDigit.hasMatch(last)) {
        u = cut; // emoji, variation selectors, symbols
      } else {
        break;
      }
    }
    return u;
  }

  /// Every link in [text], cleaned and de-duplicated, in order. Never throws.
  static List<String> findUrls(String text, {int max = 3}) {
    final out = <String>{};
    for (final m in urlPattern.allMatches(text)) {
      try {
        final u = clean(trimUrl(m.group(0)!));
        if (u.host.isEmpty || !u.host.contains('.') && u.host != 'localhost') continue;
        out.add(u.toString());
      } catch (_) {
        // A malformed link is just text.
      }
      if (out.length >= max) break;
    }
    return out.toList();
  }

  /// Removes tracking parameters, credentials and fragments; keeps what
  /// identifies the content (YouTube's v, t and list; repeated keys).
  static Uri clean(String raw) {
    var s = raw.trim();
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) s = 'https://$s';
    // Unicode hosts go out as punycode, which is what DNS understands.
    final hostMatch = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)(?:[^/?#@]*@)?([^/?#:]*)').firstMatch(s);
    if (hostMatch != null && hostMatch.group(2)!.runes.any((c) => c > 0x7f)) {
      final host = hostMatch.group(2)!.toLowerCase().split('.').map(_punycode).join('.');
      s = '${hostMatch.group(1)}$host${s.substring(hostMatch.end)}';
    }
    final u = Uri.parse(s);
    final query = [
      for (final part in u.query.split('&'))
        if (part.isNotEmpty && !_tracking.contains(_queryKey(part).toLowerCase())) part,
    ];
    return Uri.parse(
      '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}${u.path}${query.isEmpty ? '' : '?${query.join('&')}'}',
    );
  }

  static String _queryKey(String part) {
    final k = part.split('=').first;
    try {
      return Uri.decodeQueryComponent(k);
    } catch (_) {
      return k;
    }
  }

  /// RFC 3492 punycode for one host label ("münchen" → "xn--mnchen-3ya").
  static String _punycode(String label) {
    final input = label.runes.toList();
    if (input.every((c) => c < 0x80)) return label;
    const base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700;
    final out = StringBuffer();
    for (final c in input.where((c) => c < 0x80)) {
      out.writeCharCode(c);
    }
    final b = out.length;
    var h = b;
    if (b > 0) out.write('-');
    var n = 128, delta = 0, bias = 72;
    int adapt(int d, int points, bool first) {
      d = first ? d ~/ damp : d ~/ 2;
      d += d ~/ points;
      var k = 0;
      while (d > ((base - tmin) * tmax) ~/ 2) {
        d ~/= base - tmin;
        k += base;
      }
      return k + ((base - tmin + 1) * d) ~/ (d + skew);
    }

    String digit(int d) => String.fromCharCode(d < 26 ? 97 + d : 22 + d);
    while (h < input.length) {
      final m = input.where((c) => c >= n).reduce((a, c) => a < c ? a : c);
      delta += (m - n) * (h + 1);
      n = m;
      for (final c in input) {
        if (c < n) delta++;
        if (c == n) {
          var q = delta;
          for (var k = base; ; k += base) {
            final t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias);
            if (q < t) break;
            out.write(digit(t + (q - t) % (base - t)));
            q = (q - t) ~/ (base - t);
          }
          out.write(digit(q));
          bias = adapt(delta, h + 1, h == b);
          delta = 0;
          h++;
        }
      }
      delta++;
      n++;
    }
    return 'xn--$out';
  }

  static String platformOf(Uri u) {
    final h = u.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|mobile)\.'), '');
    // A real subdomain or the domain itself; "notyoutube.com" is just a website.
    bool on(String d) => h == d || h.endsWith('.$d');
    if (h == 'youtu.be' || on('youtube.com')) return 'youtube';
    if (on('tiktok.com')) return 'tiktok';
    if (on('instagram.com')) return 'instagram';
    if (on('threads.net') || on('threads.com')) return 'threads';
    if (on('linkedin.com') || h == 'lnkd.in') return 'linkedin';
    if (h == 'github.com') return 'github';
    if (on('medium.com')) return 'medium';
    if (h == 'x.com' || h == 'twitter.com') return 'x';
    return 'web';
  }

  /// Answers that mean "stop asking": back off rather than try another way.
  static bool isRefusal(int? status) => status == 401 || status == 403 || status == 429;

  Future<LinkPreview> preview(String raw) async {
    Uri uri;
    try {
      uri = clean(raw);
    } catch (_) {
      return LinkPreview(url: raw.trim(), platform: 'web', title: raw.trim());
    }
    final hosts = <String>{};
    if (_isShortLink(uri)) {
      try {
        uri = await _expand(uri, hosts);
      } catch (_) {
        // Offline or timed out: keep the short link.
      }
    }
    final platform = platformOf(uri);
    final p = LinkPreview(url: uri.toString(), platform: platform, kind: _kindFromPath(platform, uri));
    p.hosts.addAll(hosts);
    try {
      switch (platform) {
        case 'youtube':
          await _oembed(p, Uri.https('www.youtube.com', '/oembed', {'url': p.url, 'format': 'json'}));
        case 'tiktok':
          await _oembed(p, Uri.https('www.tiktok.com', '/oembed', {'url': p.url}));
        case 'github':
          await _github(p, uri);
        case 'threads':
          await _htmlOembed(p, Uri.https('graph.threads.com', '/oembed', {'url': p.url}), 'Threads embed');
        case 'x' when uri.path.contains('/status/'):
          await _htmlOembed(
            p,
            Uri.https('publish.twitter.com', '/oembed', {'url': p.url, 'omit_script': '1', 'dnt': 'true'}),
            'X embed',
          );
      }
      // A refusal from the site's own endpoint means back off, not try the page.
      if (!p.rich && !isRefusal(p.status)) await _meta(p, uri);
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

  Future<http.Response> _get(LinkPreview p, Uri uri, Map<String, String> headers) {
    p.hosts.add(uri.host);
    return _client.get(uri, headers: headers).timeout(timeout);
  }

  /// Decodes a JSON object leniently (bad bytes are replaced, not fatal).
  static Map<String, dynamic>? _jsonObject(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  // ── sources ──────────────────────────────────────────────────────────────

  Future<void> _oembed(LinkPreview p, Uri endpoint) async {
    final res = await _get(p, endpoint, {'User-Agent': _ua});
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final j = _jsonObject(res);
    if (j == null) return;
    p
      ..author = _str(j['author_name']) ?? p.author
      ..imageUrl = _str(j['thumbnail_url']) ?? p.imageUrl;
    // Some embeds answer without a title (e.g. TikTok videos with embedding limited).
    final title = _str(j['title']);
    if (title != null) {
      p
        ..title = title
        ..via = 'oembed';
    }
  }

  /// Meta's tokenless oEmbed (Threads) and X's publish oEmbed return the post
  /// as an HTML blockquote; its text is the post.
  Future<void> _htmlOembed(LinkPreview p, Uri endpoint, String from) async {
    final res = await _get(p, endpoint, {'User-Agent': _ua});
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final j = _jsonObject(res);
    if (j == null) return;
    final html = '${j['html'] ?? ''}';
    final para = RegExp(r'<p\b[^>]*>([\s\S]*?)</p>', caseSensitive: false).allMatches(html).map((m) => m.group(1)!);
    var text = htmlToText(para.isEmpty ? html : para.join('\n'))
        .split('\n')
        .where(
          (l) =>
              !RegExp(r'^(view on threads|post by|a post shared by|view this post)', caseSensitive: false).hasMatch(l),
        )
        .join('\n')
        .trim();
    if (text.isEmpty) return;
    final author = _str(j['author_name']);
    p
      ..author = author ?? p.author
      ..body = text
      ..bodyFrom = from
      ..description = text.length > 300 ? '${text.substring(0, 297)}…' : text
      ..title = '${author ?? p.platform}: ${text.split('\n').first}'
      ..kind = 'post'
      ..via = 'oembed';
  }

  /// Turns an HTML fragment into readable plain text, keeping paragraph breaks.
  static String htmlToText(String html) =>
      decodeEntities(
            html
                .replaceAll(RegExp(r'<(script|style)\b[\s\S]*?</\1>', caseSensitive: false), '')
                .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
                .replaceAll(RegExp(r'</(p|div|h[1-6]|li|blockquote|pre|figure|tr)>', caseSensitive: false), '\n')
                .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '• ')
                .replaceAll(RegExp(r'<[^>]+>'), ''),
          )
          .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
          .replaceAll(RegExp(r' *\n *'), '\n')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();

  Future<void> _github(LinkPreview p, Uri uri) async {
    final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (seg.length < 2) return;
    final res = await _get(p, Uri.https('api.github.com', '/repos/${seg[0]}/${seg[1]}'), {
      'Accept': 'application/vnd.github+json',
      'User-Agent': _ua,
    });
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final j = _jsonObject(res);
    if (j == null) return;
    final stars = j['stargazers_count'];
    p
      ..title = _str(j['full_name']) ?? '${seg[0]}/${seg[1]}'
      ..description = [
        _str(j['description']),
        _str(j['language']),
        if (stars is num) '★ $stars',
      ].whereType<String>().join(' · ')
      ..author = j['owner'] is Map ? _str((j['owner'] as Map)['login']) : null
      ..imageUrl = 'https://opengraph.githubassets.com/1/${seg[0]}/${seg[1]}'
      ..kind = 'repo'
      ..via = 'api';
  }

  Future<void> _meta(LinkPreview p, Uri uri) async {
    final res = await _get(p, uri, {
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml',
      'Accept-Language': 'en',
    });
    p.status = res.statusCode;
    if (res.statusCode != 200) return;
    final bytes = res.bodyBytes.length > 2000000 ? res.bodyBytes.sublist(0, 2000000) : res.bodyBytes;
    final charset = RegExp(
      r'charset=([\w-]+)',
      caseSensitive: false,
    ).firstMatch(res.headers['content-type'] ?? '')?.group(1)?.toLowerCase();
    final text = const {'iso-8859-1', 'latin1', 'latin-1', 'windows-1252', 'us-ascii'}.contains(charset)
        ? latin1.decode(bytes, allowInvalid: true)
        : utf8.decode(bytes, allowMalformed: true);
    final m = parseMeta(text);
    final title = m['og:title'] ?? m['twitter:title'] ?? m['title'];
    if (title == null || isGenericTitle(title)) {
      p.walled = true;
      return;
    }
    final image = m['og:image'] ?? m['twitter:image'];
    p
      ..title = title
      ..description = m['og:description'] ?? m['twitter:description'] ?? m['description']
      ..imageUrl = image == null ? null : _absolute(uri, image)
      ..author = p.author ?? m['author'] ?? m['article:author']
      ..via = 'meta';
  }

  /// og:image is often relative ("/img/cover.png"); resolve it against the page.
  static String? _absolute(Uri page, String src) {
    try {
      final u = page.resolve(src.trim());
      return u.scheme == 'https' || u.scheme == 'http' ? u.toString() : null;
    } catch (_) {
      return null;
    }
  }

  // ── parsing ──────────────────────────────────────────────────────────────

  /// Pulls Open Graph, Twitter and basic meta tags out of HTML. Scans in
  /// linear time (quotes respected, each tag bounded), so a hostile or broken
  /// page can't freeze the app.
  static Map<String, String> parseMeta(String html) {
    final out = <String, String>{};
    final head = html.length > 400000 ? html.substring(0, 400000) : html;
    final lower = head.toLowerCase();
    final attrRe = RegExp('([a-zA-Z:_-]+)\\s*=\\s*("([^"]*)"|\'([^\']*)\')');
    var i = 0;
    while (true) {
      final start = lower.indexOf('<meta', i);
      if (start < 0) break;
      final after = start + 5;
      if (after < lower.length && RegExp(r'[\w-]').hasMatch(lower[after])) {
        i = after;
        continue;
      }
      String? quote;
      var end = -1;
      final limit = (after + 4000).clamp(0, head.length);
      for (var k = after; k < limit; k++) {
        final ch = head[k];
        if (quote != null) {
          if (ch == quote) quote = null;
        } else if (ch == '"' || ch == "'") {
          quote = ch;
        } else if (ch == '>') {
          end = k;
          break;
        } else if (ch == '<') {
          break; // a new tag began: this one was never closed
        }
      }
      if (end < 0) {
        i = after;
        continue;
      }
      final attrs = <String, String>{};
      for (final a in attrRe.allMatches(head.substring(after, end))) {
        attrs.putIfAbsent(a.group(1)!.toLowerCase(), () => a.group(3) ?? a.group(4) ?? '');
      }
      final key = (attrs['property'] ?? attrs['name'] ?? attrs['itemprop'])?.toLowerCase();
      final value = attrs['content'];
      if (key != null && value != null && value.trim().isNotEmpty) {
        out.putIfAbsent(key, () => decodeEntities(value.trim()));
      }
      i = end + 1;
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
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]{1,8});'), (m) => _char(int.parse(m.group(1)!, radix: 16)))
      .replaceAllMapped(RegExp(r'&#(\d{1,9});'), (m) => _char(int.parse(m.group(1)!)))
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  /// An out-of-range entity becomes the replacement character, not a crash.
  static String _char(int code) =>
      code <= 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) ? '\uFFFD' : String.fromCharCode(code);

  /// Login walls and error pages return a title but not a useful one.
  static bool isGenericTitle(String t) {
    final l = t.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
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
      'not found',
      'forbidden',
      'too many requests',
      'verify you are human',
      'are you a robot?',
      'log in',
      'login',
      'sign in',
      'sign up',
      'error',
    };
    if (generic.contains(l)) return true;
    // "Threads • Log in", "Log in • Instagram", "LinkedIn Login, Sign in | LinkedIn"
    if (RegExp(r'(^|[•|,·-] ?)(log ?in|sign ?in|sign ?up)( ?[•|,·-]|$)').hasMatch(l)) return true;
    if (RegExp(r'^(log ?in|sign ?in|sign ?up)\b').hasMatch(l) &&
        RegExp(r'\b(instagram|threads|facebook|linkedin|tiktok|twitter|x|medium|youtube|your account|continue)\b')
            .hasMatch(l) &&
        l.length < 40) {
      return true;
    }
    // Soft error pages served with HTTP 200.
    return RegExp(r'^(4\d\d|5\d\d)\b').hasMatch(l) || RegExp(r'^error \d{3}\b').hasMatch(l);
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
  Future<Uri> _expand(Uri u, Set<String> hosts) async {
    var current = u;
    for (var i = 0; i < 5; i++) {
      hosts.add(current.host);
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
    final seg = u.pathSegments.where((s) => s.isNotEmpty).map((s) => s.toLowerCase()).toList();
    return switch (platform) {
      'youtube' when u.host.toLowerCase() == 'youtu.be' => 'video',
      'youtube' when seg.isNotEmpty && seg.first.startsWith('@') => 'profile',
      'youtube' when seg.isNotEmpty && const {'channel', 'c', 'user'}.contains(seg.first) => 'profile',
      'youtube' when seg.isNotEmpty && seg.first == 'playlist' => 'playlist',
      'youtube' => 'video',
      'tiktok' when seg.contains('video') => 'video',
      'tiktok' when seg.contains('photo') => 'post',
      'tiktok' => path.contains('/@') ? 'profile' : 'video',
      'instagram' when seg.isNotEmpty && seg.first == 'stories' => 'story',
      'instagram' when seg.any((s) => const {'reel', 'reels', 'tv'}.contains(s)) => 'video',
      'instagram' when seg.contains('p') => 'post',
      'instagram' => 'profile',
      'threads' => seg.contains('post') || (seg.isNotEmpty && seg.first == 't') ? 'post' : 'profile',
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
    if (platform == 'github' && seg.length >= 2) {
      final repo = '${seg[0]}/${seg[1]}';
      if (seg.length >= 4 && const {'issues', 'pull'}.contains(seg[2])) return '$repo #${seg[3]}';
      if (seg.length >= 3 && const {'blob', 'tree'}.contains(seg[2])) return '$repo · ${seg.last}';
      return repo;
    }
    if (platform == 'youtube') {
      if (handle.isNotEmpty) return '$handle on YouTube';
      final id = u.queryParameters['v'] ?? (seg.length >= 2 ? seg[1] : (u.host == 'youtu.be' ? seg.first : null));
      return id == null || id.isEmpty ? 'YouTube $kind' : 'YouTube $kind $id';
    }
    // Social posts have opaque ids; name them by kind and author instead.
    if (const {'tiktok', 'instagram', 'threads', 'x'}.contains(platform)) {
      final label = const {'tiktok': 'TikTok', 'instagram': 'Instagram', 'threads': 'Threads', 'x': 'X'}[platform]!;
      if (kind == 'story') return seg.length >= 2 ? '$label story by @${seg[1]}' : '$label story';
      final name = handle.isNotEmpty ? handle : (kind == 'profile' ? '@${seg.first}' : '');
      if (kind == 'profile') return '$name on $label';
      return name.isEmpty ? '$label $kind' : '$label $kind by $name';
    }
    // pathSegments are already decoded; decoding again breaks on "100%".
    var last = seg.last.replaceAll(RegExp(r'\.(html?|php)$'), '');
    // Medium-style slugs end in a hex id: "software-2-0-a64152b37c35".
    last = last.replaceFirst(RegExp(r'-[0-9a-f]{8,12}$'), '');
    if (seg.length >= 2 && RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(last) && !last.contains('-')) {
      return '${seg.first.startsWith('@') ? seg.first : host} · ${seg[seg.length - 2]}';
    }
    final words = last.split(RegExp(r'[-_+]')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return host;
    final title = words.join(' ');
    final pretty = '${title[0].toUpperCase()}${title.substring(1)}';
    return handle.isEmpty || pretty == handle ? pretty : '$pretty · $handle';
  }

  void close() => _client.close();
}
