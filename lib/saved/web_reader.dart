import 'dart:convert';

import 'package:http/http.dart' as http;

/// Optional, free fallback that turns a public page into plain text when the
/// page's own preview tags say too little (long articles, blogs, news).
/// Callers only use it for pages the site served openly, never to get past a
/// refusal, bot check or login wall.
///
/// Uses Jina Reader's free tier (r.jina.ai): about 20 requests a minute with
/// no key, more with a free key from jina.ai. The link's URL is sent to Jina, so this is off by default and every
/// use is logged under privacy. It only sees what an anonymous visitor sees:
/// private posts and login walls stay private.
class WebReader {
  WebReader({http.Client? client, this.timeout = const Duration(seconds: 20)}) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static const name = 'Jina Reader';

  /// Returns the page as Markdown-ish text, or null when it could not be read.
  Future<String?> read(String url, {int maxChars = 8000, String apiKey = ''}) async {
    try {
      final res = await _client
          .get(
            Uri.parse('https://r.jina.ai/$url'),
            headers: {
              'Accept': 'text/plain',
              'X-Retain-Images': 'none',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final text = clean(utf8.decode(res.bodyBytes, allowMalformed: true));
      if (text.length < 80 || looksBlocked(text)) return null;
      return text.length > maxChars ? '${text.substring(0, maxChars)}…' : text;
    } catch (_) {
      return null;
    }
  }

  /// Drops Jina's header lines, link targets and blank runs so the model gets prose.
  static String clean(String raw) {
    var s = raw;
    final body = s.indexOf('Markdown Content:');
    if (body >= 0) s = s.substring(body + 'Markdown Content:'.length);
    return s
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '') // images
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!) // links → text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// Login walls and bot checks come back as short pages about signing in.
  static bool looksBlocked(String text) {
    final head = (text.length > 1500 ? text.substring(0, 1500) : text).toLowerCase();
    // Bot checks and block pages that the reader relays with HTTP 200.
    const blocks = [
      'just a moment',
      'verify you are human',
      'enable javascript',
      'access denied',
      'you have been blocked',
      'returned error 403',
      'returned error 401',
      'returned error 429',
      'security check',
      'checking your browser',
      'cloudflare ray id',
      'unusual traffic',
      'captcha',
      'are you a robot',
    ];
    if (text.length < 2500 && blocks.any(head.contains)) return true;
    return text.length < 900 && (head.contains('log in') || head.contains('sign in'));
  }

  void close() => _client.close();
}
