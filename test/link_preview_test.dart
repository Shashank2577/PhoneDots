import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/saved/link_preview.dart';

void main() {
  group('clean', () {
    test('strips tracking but keeps what identifies the content', () {
      expect(
        LinkPreviewer.clean('https://www.youtube.com/watch?v=abc&si=XYZ&feature=share').toString(),
        'https://www.youtube.com/watch?v=abc',
      );
      expect(LinkPreviewer.clean('https://youtu.be/abc?si=x').toString(), 'https://youtu.be/abc');
      expect(
        LinkPreviewer.clean('https://www.instagram.com/p/C1/?igsh=MTc=').toString(),
        'https://www.instagram.com/p/C1/',
      );
      expect(
        LinkPreviewer.clean('https://www.threads.net/@a/post/B?xmt=AQ').toString(),
        'https://www.threads.net/@a/post/B',
      );
      expect(
        LinkPreviewer.clean('https://example.com/a?utm_source=x&id=7#frag').toString(),
        'https://example.com/a?id=7',
      );
      expect(LinkPreviewer.clean('github.com/o/r').toString(), 'https://github.com/o/r');
    });

    test('platforms', () {
      for (final (url, platform) in [
        ('https://m.youtube.com/watch?v=1', 'youtube'),
        ('https://youtu.be/1', 'youtube'),
        ('https://vm.tiktok.com/ZM1/', 'tiktok'),
        ('https://www.instagram.com/reel/1/', 'instagram'),
        ('https://www.threads.com/@a', 'threads'),
        ('https://lnkd.in/abc', 'linkedin'),
        ('https://github.com/a/b', 'github'),
        ('https://karpathy.medium.com/x', 'medium'),
        ('https://x.com/a', 'x'),
        ('https://example.org/', 'web'),
      ]) {
        expect(LinkPreviewer.platformOf(Uri.parse(url)), platform, reason: url);
      }
    });
  });

  test('parseMeta handles attribute order, quotes and entities', () {
    const html = '''<html><head><title>Fallback &amp; title</title>
      <meta content="A &quot;quoted&quot; title" property="og:title">
      <meta property='og:description' content='isn&amp;#39;t double-escaped'>
      <meta name="twitter:image" content="https://img/x.png"/></head></html>''';
    final m = LinkPreviewer.parseMeta(html);
    expect(m['og:title'], 'A "quoted" title');
    expect(m['og:description'], "isn't double-escaped");
    expect(m['twitter:image'], 'https://img/x.png');
    expect(m['title'], 'Fallback & title');
  });

  group('preview with a fake network', () {
    http.Response page(String title, {String desc = 'd'}) => http.Response(
      '<meta property="og:title" content="$title"><meta property="og:description" content="$desc">',
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );

    test('YouTube uses oEmbed', () async {
      final p = LinkPreviewer(
        client: MockClient((r) async {
          expect(r.url.path, '/oembed');
          return http.Response(
            jsonEncode({'title': 'A video', 'author_name': 'Chan', 'thumbnail_url': 'https://t'}),
            200,
          );
        }),
      );
      final r = await p.preview('https://youtu.be/abc?si=1');
      expect((r.title, r.author, r.via, r.kind), ('A video', 'Chan', 'oembed', 'video'));
    });

    test('a login wall is not a title; falls back to the URL', () async {
      final p = LinkPreviewer(client: MockClient((_) async => page('Threads • Log in')));
      final r = await p.preview('https://www.threads.net/@ana/post/DIswUS-MfNp');
      expect((r.title, r.via, r.kind), ('Threads post by @ana', 'url', 'post'));
    });

    test('blocked pages still get a readable title', () async {
      final p = LinkPreviewer(client: MockClient((_) async => http.Response('Just a moment...', 403)));
      final r = await p.preview('https://medium.com/@karpathy/software-2-0-a64152b37c35');
      expect(r.title, 'Software 2 0 · @karpathy');
      expect(r.rich, isFalse);
    });

    test('TikTok oEmbed without a title falls through to the page', () async {
      final p = LinkPreviewer(
        client: MockClient(
          (r) async => r.url.path == '/oembed'
              ? http.Response(jsonEncode({'type': 'video', 'author_name': 'scout'}), 200)
              : page('Cute dogs | TikTok'),
        ),
      );
      final r = await p.preview('https://www.tiktok.com/@scout2015/video/1?is_from_webapp=1');
      expect((r.title, r.author, r.via), ('Cute dogs', 'scout', 'meta'));
      expect(r.url, 'https://www.tiktok.com/@scout2015/video/1');
    });

    test('GitHub uses the API', () async {
      final p = LinkPreviewer(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'full_name': 'o/r',
              'description': 'Tools',
              'language': 'Dart',
              'stargazers_count': 5,
              'owner': {'login': 'o'},
            }),
            200,
          ),
        ),
      );
      final r = await p.preview('https://github.com/o/r');
      expect((r.title, r.description, r.kind), ('o/r', 'Tools · Dart · ★ 5', 'repo'));
    });

    test('network failure never throws', () async {
      final p = LinkPreviewer(client: MockClient((_) async => throw Exception('offline')));
      final r = await p.preview('https://www.instagram.com/p/C1/');
      expect(r.title, 'Instagram post');
    });
  });
}
