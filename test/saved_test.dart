import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/saved/link_preview.dart';
import 'package:phonedots/saved/saved_store.dart';
import 'package:phonedots/saved/summarizer.dart';
import 'package:phonedots/saved/web_reader.dart';

const _reel = '''
<html><head>
<meta property="og:title" content="Chef Ana on Instagram: &quot;3-ingredient pasta&quot;">
<meta property="og:description" content="Boil pasta. Toss with butter and parmesan. Add pepper. Done in 10 minutes!">
<meta property="og:image" content="https://cdn.example.com/cover.jpg">
</head></html>''';

MockClient _web({List<String>? log}) => MockClient((req) async {
  log?.add(req.url.toString());
  if (req.url.host == 'r.jina.ai') {
    return http.Response(
      'Title: Long read\nURL Source: x\nMarkdown Content:\n${'A long article body about Flutter performance. ' * 10}',
      200,
    );
  }
  if (req.url.host == 'www.instagram.com') return http.Response(_reel, 200, headers: {'content-type': 'text/html'});
  if (req.url.host == 'medium.com') return http.Response('blocked', 403);
  if (req.url.host == 'blog.example.com') {
    return http.Response('<title>Flutter speed</title><meta name="description" content="Tips.">', 200);
  }
  return http.Response('', 404);
});

Future<(Summarizer, SavedStore, AppSettings, List<String>)> _setup({
  required AskModel ask,
  bool webReader = false,
}) async {
  final store = MemoryJsonStore();
  final settings = AppSettings(store);
  await settings.update((s) => s.webReader = webReader);
  final saved = SavedStore(store);
  final log = <String>[];
  final client = _web(log: log);
  final sum = Summarizer(
    store: saved,
    links: LinkPreviewer(client: client),
    reader: WebReader(client: client),
    settings: settings,
    ledger: Ledger(store),
    ask: ask,
    canSee: () => false,
    client: client,
  );
  return (sum, saved, settings, log);
}

void main() {
  test('a shared reel is read from its caption and summarised from the JSON reply', () async {
    final (sum, saved, _, _) = await _setup(
      ask: ({required system, required prompt, imagePaths = const []}) async {
        expect(system, contains('JSON'));
        expect(system, contains('recipes'));
        expect(prompt, contains('Boil pasta'));
        return '```json\n{"title": "3-ingredient pasta", "summary": "A ten-minute butter and parmesan pasta.", '
            '"points": ["Boil pasta", "Toss with butter and parmesan", "Add pepper"], '
            '"collection": "Recipes", "tags": ["#pasta", "quick"]}\n```';
      },
    );
    final item = await sum.addShare(text: 'Look at this https://www.instagram.com/reel/C9xyz/?igsh=abc');
    expect(item.url, 'https://www.instagram.com/reel/C9xyz/');
    expect(item.sharedText, 'Look at this');
    await sum.resummarise(item);
    expect(item.status, SavedStatus.done);
    expect(item.platform, 'instagram');
    expect(item.kind, 'video');
    expect(item.description, contains('Boil pasta'));
    expect(item.summary, 'A ten-minute butter and parmesan pasta.');
    expect(item.points, hasLength(3));
    expect(item.collection, 'recipes');
    expect(item.tags, ['pasta', 'quick']);
    expect(item.sources, containsAll(['caption', 'page preview']));
    expect(saved.collections, ['recipes']);
    expect(saved.search('parmesan'), [item]);
  });

  test('the prompt carries everything gathered and forbids inventing scenes', () {
    final i = SavedItem(
      id: '1',
      created: DateTime(2026),
      url: 'https://www.tiktok.com/@a/video/1',
      platform: 'tiktok',
      kind: 'video',
      title: 'TikTok video by @a',
      sharedText: 'Best hike in Spain #travel',
    );
    final m = Summarizer.material(i, pageText: null, transcript: 'hello everyone');
    expect(m, contains('Best hike in Spain'));
    expect(m, contains('Transcript:\nhello everyone'));
    expect(Summarizer.systemPrompt(['travel']), contains('do not describe scenes you cannot see'));
  });

  test('non-JSON replies still become a summary with points', () {
    final i = SavedItem(id: '1', created: DateTime(2026));
    Summarizer.apply(i, 'A guide to sourdough.\n- Feed the starter\n- Bake at 250C');
    expect(i.summary, 'A guide to sourdough.');
    expect(i.points, ['Feed the starter', 'Bake at 250C']);
    expect(i.collection, 'other');
  });

  test('without a model the item is kept and waits', () async {
    final (sum, saved, _, _) = await _setup(
      ask: ({required system, required prompt, imagePaths = const []}) async =>
          throw const NoModelError('Download Gemma 4 E2B in models first.'),
    );
    final item = await sum.addShare(text: 'https://www.instagram.com/reel/C9xyz/');
    await sum.resummarise(item);
    expect(item.status, SavedStatus.needsModel);
    expect(item.title, contains('3-ingredient pasta'));
    expect(saved.items, [item]);
  });

  test('the free web reader is only asked when it is switched on and the preview is thin', () async {
    for (final on in [false, true]) {
      String? seen;
      final (sum, _, _, log) = await _setup(
        webReader: on,
        ask: ({required system, required prompt, imagePaths = const []}) async {
          seen = prompt;
          return '{"summary": "ok", "collection": "tech"}';
        },
      );
      final item = await sum.addShare(text: 'https://blog.example.com/flutter-speed');
      await sum.resummarise(item);
      expect(log.any((u) => u.startsWith('https://r.jina.ai/')), on);
      expect(seen!.contains('Flutter performance'), on);
      expect(item.sources.contains('Jina Reader'), on);
    }
  });

  test('the web reader is never used to get past a refusal or a login wall', () async {
    final (sum, _, _, log) = await _setup(
      webReader: true,
      ask: ({required system, required prompt, imagePaths = const []}) async => '{"summary": "ok"}',
    );
    final blocked = await sum.addShare(text: 'https://medium.com/@me/flutter-speed-1234abcd5678');
    await sum.resummarise(blocked);
    expect(log.where((u) => u.startsWith('https://r.jina.ai/')), isEmpty);
    expect(blocked.status, SavedStatus.done);
  });

  test('web reader ignores login walls', () {
    expect(WebReader.looksBlocked('Log in to Instagram to see this'), isTrue);
    expect(WebReader.clean('Title: x\nMarkdown Content:\nHi [there](https://a.b) ![img](c)'), 'Hi there');
  });

  test('shares with a link go to saved; plain text still opens a chat', () async {
    final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo', linkClient: _web());
    await s.receiveShare(text: 'just some words');
    expect(s.intake.value?.text, 'just some words');
    expect(s.saved.items, isEmpty);

    await s.receiveShare(text: 'https://www.instagram.com/reel/C9xyz/', subject: 'Pasta');
    expect(s.saved.items, hasLength(1));
    expect(s.savedArrived.value, s.saved.items.first.id);
    await s.summarizer.resummarise(s.saved.items.first);
    final item = s.saved.items.first;
    // The demo engine answers with an extractive summary of the material.
    expect(item.status, SavedStatus.done);
    expect(item.summary, isNotNull);
    expect(s.ledger.entries.any((e) => e.network && e.detail.contains('instagram')), isTrue);
  });
}
