import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/saved/deep_reader.dart';
import 'package:phonedots/saved/link_preview.dart';
import 'package:phonedots/saved/saved_store.dart';
import 'package:phonedots/saved/summarizer.dart';
import 'package:phonedots/saved/web_reader.dart';

const _watch = '''<html><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"},
"videoDetails":{"videoId":"abc","title":"Knife skills","lengthSeconds":"754","keywords":["cooking","knife"],
"shortDescription":"Learn 5 cuts.\\n\\n0:00 Intro\\n1:10 Julienne \\"fast\\"","author":"Chef"}};</script></html>''';

const _rss = '''<?xml version="1.0"?><rss><channel>
<item><title><![CDATA[Other story]]></title><guid>https://medium.com/p/111111111111</guid>
<content:encoded><![CDATA[<p>nope</p>]]></content:encoded></item>
<item><title><![CDATA[Software 2.0]]></title><link>https://karpathy.medium.com/software-2-0-a64152b37c35?source=rss</link>
<guid isPermaLink="false">https://medium.com/p/a64152b37c35</guid><dc:creator><![CDATA[Andrej Karpathy]]></dc:creator>
<content:encoded><![CDATA[<h3>Software 2.0</h3><figure><img src="https://cdn-images-1.medium.com/x.png"></figure><p>Neural networks are not just another tool.</p><ul><li>One</li><li>Two</li></ul>]]></content:encoded></item>
</channel></rss>''';

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json; charset=utf-8'});

MockClient _client(List<String> log) => MockClient((req) async {
  log.add(req.url.toString());
  final u = req.url;
  switch (u.host) {
    case 'www.youtube.com' when u.path == '/oembed':
      return _json({'title': 'Knife skills', 'author_name': 'Chef', 'thumbnail_url': 'https://i.ytimg.com/a.jpg'});
    case 'www.youtube.com' when u.path == '/watch' && u.queryParameters['v'] == 'wall':
      return http.Response('{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in"}', 200);
    case 'www.youtube.com' when u.path == '/watch':
      return http.Response(_watch, 200);
    case 'www.googleapis.com':
      return _json({
        'items': [
          {
            'snippet': {
              'title': 'API title',
              'channelTitle': 'API channel',
              'description': 'Full API description',
              'tags': ['a', 'b'],
            },
            'contentDetails': {'duration': 'PT1H2M3S'},
          },
        ],
      });
    case 'api.github.com' when u.path.endsWith('/readme'):
      return http.Response(
        '# Tool\n[![CI](https://x/badge.svg)](https://x)\n![logo](logo.png)\nDoes <b>things</b>. See [docs](https://d).',
        200,
      );
    case 'api.github.com':
      return _json({
        'full_name': 'o/tool',
        'description': 'A tool',
        'owner': {'login': 'o'},
      });
    case 'medium.com' when u.path.startsWith('/feed/'):
      return http.Response(_rss, 200);
    case 'graph.threads.com':
      return _json({
        'author_name': 'mosseri',
        'html':
            '<blockquote class="text-post-media"><p>Shipping a new feed today &amp; more</p>'
            '<a href="#">View on Threads</a></blockquote>',
      });
    case 'publish.twitter.com':
      return _json({
        'author_name': 'Google Devs',
        'html': '<blockquote class="twitter-tweet"><p lang="en">Gemma 4 is here 🎉</p>&mdash; Google</blockquote>',
      });
  }
  return http.Response('', 404);
});

void main() {
  late List<String> log;
  late LinkPreviewer links;
  late DeepReader deep;

  setUp(() {
    log = [];
    final c = _client(log);
    links = LinkPreviewer(client: c);
    deep = DeepReader(client: c);
  });

  Future<LinkPreview> read(String url, {String youtubeKey = ''}) async {
    final p = await links.preview(url);
    await deep.read(p, youtubeKey: youtubeKey);
    return p;
  }

  test('YouTube videos and Shorts: full description, chapters, length and tags from the page', () async {
    for (final url in ['https://youtu.be/abc?si=x', 'https://www.youtube.com/shorts/abc']) {
      final p = await read(url);
      expect(p.title, 'Knife skills');
      expect(p.bodyFrom, 'YouTube page');
      expect(p.body, contains('Length: 12m 34s'));
      expect(p.body, contains('Tags: cooking, knife'));
      expect(p.body, contains('1:10 Julienne "fast"'));
    }
  });

  test('YouTube: a free Data API key is used first; a bot-check page is never read', () async {
    final api = await read('https://www.youtube.com/watch?v=abc', youtubeKey: 'KEY');
    expect(api.bodyFrom, 'YouTube Data API');
    expect(api.body, contains('Length: 1h 2m'));
    expect(api.author, 'API channel');
    expect(log.where((u) => u.contains('/watch?')), isEmpty);

    final wall = await read('https://www.youtube.com/watch?v=wall');
    expect(wall.body, isNull);
    expect(wall.title, 'Knife skills'); // the official oEmbed still names it
  });

  test('GitHub: the README, without badges, images or link targets', () async {
    final p = await read('https://github.com/o/tool');
    expect(p.bodyFrom, 'README');
    expect(p.body, startsWith('# Tool'));
    expect(p.body, contains('Does things. See docs.'));
    expect(p.body, isNot(contains('badge')));
  });

  test('Medium: the full free article from the official RSS feed', () async {
    for (final url in [
      'https://medium.com/@karpathy/software-2-0-a64152b37c35',
      'https://karpathy.medium.com/software-2-0-a64152b37c35',
    ]) {
      final p = await read(url);
      expect(p.title, 'Software 2.0');
      expect(p.author, 'Andrej Karpathy');
      expect(p.bodyFrom, 'Medium RSS');
      expect(p.body, contains('Neural networks are not just another tool.'));
      expect(p.body, contains('• One'));
      expect(p.imageUrl, isNotNull);
    }
    expect(log, contains('https://medium.com/feed/@karpathy'));
    expect(
      DeepReader.mediumFeed(Uri.parse('https://medium.com/towards-data-science/x-1234567890ab')).toString(),
      'https://medium.com/feed/towards-data-science',
    );
  });

  test('Threads and X posts: the text from their official oEmbed', () async {
    final t = await read('https://www.threads.com/@mosseri/post/ABC');
    expect(t.body, 'Shipping a new feed today & more');
    expect(t.author, 'mosseri');
    final x = await read('https://x.com/googledevs/status/123');
    expect(x.body, 'Gemma 4 is here 🎉');
    // Profiles are not posts, so no embed is asked for.
    await read('https://x.com/googledevs');
    expect(log.where((u) => u.contains('publish.twitter.com')), hasLength(1));
  });

  test('Instagram: the caption is lifted out of the preview tags', () async {
    final p = LinkPreview(
      url: 'https://www.instagram.com/reel/X/',
      platform: 'instagram',
      kind: 'video',
      via: 'meta',
      description: '1,024 likes, 12 comments - chef.ana on May 1, 2026: "Pasta in 10 min. Boil, toss, done." ',
    );
    await deep.read(p);
    expect(p.body, 'Pasta in 10 min. Boil, toss, done.');
    expect(p.author, 'chef.ana');
  });

  test('a shared screen recording: frames for Gemma to look at, plus a transcript', () async {
    final store = MemoryJsonStore();
    final saved = SavedStore(store);
    List<String>? images;
    String? seen;
    final sum = Summarizer(
      store: saved,
      links: links,
      reader: WebReader(client: _client(log)),
      settings: AppSettings(store),
      ledger: Ledger(store),
      ask: ({required system, required prompt, imagePaths = const []}) async {
        images = imagePaths;
        seen = prompt;
        return '{"summary": "A pasta reel.", "collection": "recipes"}';
      },
      canSee: () => true,
      transcribe: (path) async => 'boil the pasta then toss it',
      videoSheet: (path) async => '/tmp/sheet.jpg',
    );
    final item = await sum.addShare(
      files: [
        {'path': '/tmp/rec.mp4', 'name': 'rec.mp4', 'kind': 'audio'},
      ],
    );
    await sum.resummarise(item);
    expect(item.status, SavedStatus.done);
    expect(images, ['/tmp/sheet.jpg']);
    expect(item.sources, containsAll(['video frames', 'transcript']));
    expect(item.body, contains('boil the pasta'));
    expect(seen, contains('frames from the shared video'));
    expect(seen, contains('Transcript:'));
  });
}
