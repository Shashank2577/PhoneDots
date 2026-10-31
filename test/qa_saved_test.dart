// QA: "Saved" (share a link / screenshot / video; PhoneDots reads it and
// summarises it with local Gemma). Edge cases and gaps that saved_test,
// deep_reader_test and link_preview_test do not cover.
//
// Tests that assert CORRECT behaviour and currently fail because of a real
// defect are marked `// BUG:` (the explanation sits next to the test).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/features/saved/saved_screen.dart';
import 'package:phonedots/main.dart';
import 'package:phonedots/saved/deep_reader.dart';
import 'package:phonedots/saved/link_preview.dart';
import 'package:phonedots/saved/saved_store.dart';
import 'package:phonedots/saved/summarizer.dart';
import 'package:phonedots/saved/web_reader.dart';
import 'package:phonedots/skills/skill.dart';

// ───────────────────────── helpers ─────────────────────────

typedef Handler = FutureOr<http.Response> Function(http.Request r);

/// A fake network that remembers every request it was asked to make.
class Net {
  Net(this.handler);
  final Handler handler;
  final log = <http.Request>[];
  late final MockClient client = MockClient((r) async {
    log.add(r);
    return handler(r);
  });
  List<String> get urls => [for (final r in log) r.url.toString()];
  Set<String> get hosts => {for (final r in log) r.url.host};
  bool contacted(String host) => hosts.contains(host);
}

http.Response html(String title, {String desc = 'a short description', Map<String, String>? headers}) => http.Response(
  '<html><head><meta property="og:title" content="$title">'
  '<meta property="og:description" content="$desc"></head></html>',
  200,
  headers: {'content-type': 'text/html; charset=utf-8', ...?headers},
);

http.Response jsonOk(Object o) => http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json'});

const _longArticle = 'A long article body about Flutter performance and rendering. ';

http.Response jina() => http.Response('Title: t\nURL Source: x\nMarkdown Content:\n${_longArticle * 10}', 200);

AskModel _ok([String reply = '{"summary": "ok", "collection": "tech"}']) =>
    ({required system, required prompt, imagePaths = const []}) async => reply;

/// Summarizer + store + ledger wired to a fake network.
class Rig {
  Rig._(this.net, this.store, this.settings, this.saved, this.ledger, this.sum, this.asks);
  final Net net;
  final MemoryJsonStore store;
  final AppSettings settings;
  final SavedStore saved;
  final Ledger ledger;
  final Summarizer sum;
  final List<String> asks;

  static Future<Rig> make({
    Handler? handler,
    AskModel? ask,
    bool webReader = false,
    bool canSee = false,
    bool autoSummarise = true,
    bool readLinks = true,
    String youtubeKey = '',
    String jinaKey = '',
    Duration timeout = const Duration(seconds: 12),
    Future<String?> Function(String)? transcribe,
    Future<String?> Function(String)? videoSheet,
    String? filesDir,
    MemoryJsonStore? store,
  }) async {
    final net = Net(handler ?? (r) => http.Response('', 404));
    final st = store ?? MemoryJsonStore();
    final settings = AppSettings(st);
    await settings.update((s) {
      s
        ..webReader = webReader
        ..autoSummarise = autoSummarise
        ..readLinks = readLinks
        ..youtubeKey = youtubeKey
        ..jinaKey = jinaKey;
    });
    final saved = SavedStore(st);
    final ledger = Ledger(st);
    final asks = <String>[];
    final inner = ask ?? _ok();
    final sum = Summarizer(
      store: saved,
      links: LinkPreviewer(client: net.client, timeout: timeout),
      reader: WebReader(client: net.client),
      settings: settings,
      ledger: ledger,
      ask: ({required system, required prompt, imagePaths = const []}) {
        asks.add(prompt);
        return inner(system: system, prompt: prompt, imagePaths: imagePaths);
      },
      canSee: () => canSee,
      transcribe: transcribe,
      videoSheet: videoSheet,
      deep: DeepReader(client: net.client),
      filesDir: filesDir,
      client: net.client,
    );
    return Rig._(net, st, settings, saved, ledger, sum, asks);
  }

  /// Network ledger lines, newest first.
  List<String> get netLines => [
    for (final e in ledger.entries)
      if (e.network) e.detail,
  ];

  Future<SavedItem> share(String text, {String? subject, List<Map<String, String>> files = const []}) async {
    final item = await sum.addShare(text: text, subject: subject, files: files);
    await settle();
    return item;
  }

  Future<void> settle({Duration within = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(within);
    while (saved.items.any((i) => i.busy)) {
      if (DateTime.now().isAfter(end)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

SavedItem item0({
  String id = '1',
  String? title,
  SavedStatus status = SavedStatus.done,
  String? summary,
  String? url,
  String platform = 'web',
  String? collection,
  String? body,
  String? description,
  List<String>? points,
  List<String>? tags,
  String? author,
  String sharedText = '',
  String? error,
  List<String>? sources,
  DateTime? created,
}) => SavedItem(
  id: id,
  created: created ?? DateTime.now(),
  title: title,
  status: status,
  summary: summary,
  url: url,
  platform: platform,
  collection: collection,
  body: body,
  description: description,
  points: points,
  tags: tags,
  author: author,
  sharedText: sharedText,
  error: error,
  sources: sources,
);

Future<LinkPreview> prev(String url, Handler h, {Duration timeout = const Duration(seconds: 2), Net? net}) {
  final n = net ?? Net(h);
  return LinkPreviewer(client: n.client, timeout: timeout).preview(url);
}

void main() {
  // ───────────────────────── URL extraction ─────────────────────────
  group('findUrls: trailing characters are not part of the link', () {
    // (shared text, the link that should be found)
    const cases = <(String, String)>[
      ('Look: https://example.com/a.', 'https://example.com/a'),
      ('https://example.com/a,', 'https://example.com/a'),
      ('wow https://example.com/a!', 'https://example.com/a'),
      ('really? https://example.com/a?', 'https://example.com/a'),
      ('(https://example.com/a)', 'https://example.com/a'),
      ('(see https://example.com/a).', 'https://example.com/a'),
      ('https://example.com/a...', 'https://example.com/a'),
      ('[https://example.com/a]', 'https://example.com/a'),
      ('{https://example.com/a}', 'https://example.com/a'),
      ('https://example.com/a;', 'https://example.com/a'),
      ('https://example.com/a:', 'https://example.com/a'),
      ('“https://example.com/a”', 'https://example.com/a'),
      ('‘https://example.com/a’', 'https://example.com/a'),
      ('«https://example.com/a»', 'https://example.com/a'),
      ('https://example.com/a。', 'https://example.com/a'),
      ('https://example.com/a…', 'https://example.com/a'),
      ('https://example.com/a😀', 'https://example.com/a'),
      ('https://example.com/a ❤️', 'https://example.com/a'),
      ('[a link](https://example.com/a)', 'https://example.com/a'),
      ('<https://example.com/a>', 'https://example.com/a'),
    ];
    for (final (text, want) in cases) {
      // BUG: the strip list is only `).,!?`; `; : ] } ” ’ » 。 …` and emoji stay glued to the URL
      // (and are then percent-encoded into the path), so the saved link is a different, usually dead, URL.
      test(text, () => expect(LinkPreviewer.findUrls(text), [want]));
    }

    // BUG: the unconditional `)` strip breaks any URL that legitimately ends in `)` (Wikipedia, MDN...).
    test('a URL that really ends in a parenthesis keeps it', () {
      expect(LinkPreviewer.findUrls('https://en.wikipedia.org/wiki/Dart_(programming_language)'), [
        'https://en.wikipedia.org/wiki/Dart_(programming_language)',
      ]);
      expect(LinkPreviewer.findUrls('(see https://en.wikipedia.org/wiki/Dart_(programming_language))'), [
        'https://en.wikipedia.org/wiki/Dart_(programming_language)',
      ]);
    });
  });

  group('findUrls: shapes of share text', () {
    test('several links: in order, de-duplicated (even with tracking noise), capped by max', () {
      const t =
          'a https://one.com/x b https://two.com/y?utm_source=z c https://two.com/y d https://three.com/z e https://four.com/w';
      expect(LinkPreviewer.findUrls(t), ['https://one.com/x', 'https://two.com/y', 'https://three.com/z']);
      expect(LinkPreviewer.findUrls(t, max: 1), ['https://one.com/x']);
      expect(LinkPreviewer.findUrls(t, max: 10), hasLength(4));
    });

    test('share text that is only a URL, with stray whitespace and newlines', () {
      expect(LinkPreviewer.findUrls('  \n https://youtu.be/abc?si=x \n\n'), ['https://youtu.be/abc']);
      expect(LinkPreviewer.findUrls('Title of video\nhttps://youtu.be/abc'), ['https://youtu.be/abc']);
    });

    test('no link: empty and plain-word shares', () {
      expect(LinkPreviewer.findUrls(''), isEmpty);
      expect(LinkPreviewer.findUrls('   '), isEmpty);
      expect(LinkPreviewer.findUrls('just some words. nothing here!'), isEmpty);
    });

    test('non-web schemes are never saved as links', () {
      for (final t in [
        'mailto:a@b.com',
        'tel:+15551234',
        'sms:123',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'content://media/external/images/1',
        'intent://scan/#Intent;scheme=zxing;end',
        'data:text/html,hi',
        'ftp://example.com/file.zip',
      ]) {
        expect(LinkPreviewer.findUrls(t), isEmpty, reason: t);
      }
    });

    // BUG: `ftp://www.example.com/x` is matched from `www.` onwards and rewritten to https://, so a
    // non-web scheme silently becomes a web link to a different resource.
    test('ftp:// with a www host is not rewritten to https', () {
      expect(LinkPreviewer.findUrls('ftp://www.example.com/x'), isEmpty);
    });

    test('bare known-host links get https://, lookalike hosts do not match', () {
      expect(LinkPreviewer.findUrls('github.com/o/r'), ['https://github.com/o/r']);
      expect(LinkPreviewer.findUrls('check youtube.com/watch?v=1 now'), ['https://youtube.com/watch?v=1']);
      expect(LinkPreviewer.findUrls('x.com/a/status/1'), ['https://x.com/a/status/1']);
      expect(LinkPreviewer.findUrls('www.example.com/a'), ['https://www.example.com/a']);
      expect(LinkPreviewer.findUrls('box.com/file'), isEmpty);
      expect(LinkPreviewer.findUrls('notgithub.com/o/r'), isEmpty);
      // An unknown bare domain is not guessed at (documented limit of the share-sheet matcher).
      expect(LinkPreviewer.findUrls('example.com/article'), isEmpty);
    });

    test('scheme and host are case-insensitive, the path keeps its case', () {
      expect(LinkPreviewer.findUrls('HTTPS://WWW.YOUTUBE.COM/watch?v=AbCdEf'), [
        'https://www.youtube.com/watch?v=AbCdEf',
      ]);
    });

    test('userinfo (credentials) is dropped, ports are kept', () {
      expect(LinkPreviewer.findUrls('http://user:secret@example.com/a'), ['http://example.com/a']);
      expect(LinkPreviewer.findUrls('https://example.com:8443/a'), ['https://example.com:8443/a']);
    });

    // BUG: Uri.parse('www.example.com:8080/x') reads "www.example.com" as the *scheme*, so clean()
    // builds the garbage `www.example.com:///8080/x`.
    test('www. link with a port', () {
      expect(LinkPreviewer.findUrls('www.example.com:8080/x'), ['https://www.example.com:8080/x']);
    });

    // BUG: clean() rebuilds the query from queryParameters (a Map), so repeated keys collapse to the last one.
    test('repeated query keys survive cleaning', () {
      expect(LinkPreviewer.findUrls('https://example.com/s?tag=a&tag=b&utm_source=x'), [
        'https://example.com/s?tag=a&tag=b',
      ]);
    });

    test('query encoding survives cleaning; tracking keys are case-insensitive; fragments drop', () {
      expect(
        LinkPreviewer.clean('https://example.com/s?q=a+b&UTM_SOURCE=x&FbClid=1#top').toString(),
        'https://example.com/s?q=a+b',
      );
      expect(LinkPreviewer.clean('https://example.com/s?q=a%2Bb').toString(), 'https://example.com/s?q=a%2Bb');
      expect(LinkPreviewer.clean('https://example.com/s?q=caf%C3%A9').toString(), 'https://example.com/s?q=caf%C3%A9');
    });

    test('YouTube timestamps and playlists are kept (they change what plays), tracking is not', () {
      expect(LinkPreviewer.findUrls('https://youtu.be/abc?t=90&si=x'), ['https://youtu.be/abc?t=90']);
      expect(LinkPreviewer.findUrls('https://youtu.be/abc?si=x&t=1m30s'), ['https://youtu.be/abc?t=1m30s']);
      expect(LinkPreviewer.findUrls('https://www.youtube.com/watch?v=abc&list=PL1&index=2&feature=shared'), [
        'https://www.youtube.com/watch?v=abc&list=PL1&index=2',
      ]);
    });

    // BUG: the percent-encoded host (`m%C3%BCnchen.de`) is not a resolvable name; IDN hosts need punycode
    // (`xn--mnchen-3ya.de`) or the unicode form passed through to the resolver.
    test('IDN / unicode hosts stay resolvable', () {
      final u = LinkPreviewer.findUrls('https://münchen.de/straße?q=ü').single;
      expect(Uri.parse(u).host, anyOf('münchen.de', 'xn--mnchen-3ya.de'));
      expect(Uri.parse(LinkPreviewer.findUrls('https://日本語.jp/ページ').single).host, isNot(contains('%')));
    });

    test('unicode in paths is percent-encoded once, not twice', () {
      final u = LinkPreviewer.findUrls('https://example.com/straße').single;
      expect(u, 'https://example.com/stra%C3%9Fe');
      expect(LinkPreviewer.findUrls(u), [u]); // idempotent
    });

    // BUG: Uri.parse throws FormatException for `http://[::1`; findUrls is not guarded, so the whole
    // share (receiveShare -> addShare) throws instead of being treated as text.
    test('malformed URLs never throw', () {
      for (final t in ['http://[::1', 'https://[', 'see http://[abc', 'https://exa mple.com']) {
        expect(() => LinkPreviewer.findUrls(t), returnsNormally, reason: t);
      }
    });

    test('a half-typed link (no host) is handled', () {
      expect(() => LinkPreviewer.findUrls('http://'), returnsNormally);
      expect(() => LinkPreviewer.findUrls('https://:80'), returnsNormally);
      expect(() => LinkPreviewer.findUrls('www.'), returnsNormally);
    });
  });

  group('platformOf', () {
    test('YouTube family and the other platforms', () {
      for (final (url, platform) in [
        ('https://music.youtube.com/watch?v=1', 'youtube'),
        ('https://m.youtube.com/watch?v=1', 'youtube'),
        ('https://www.youtube.com/shorts/1', 'youtube'),
        ('https://youtu.be/1?t=3', 'youtube'),
        ('https://vt.tiktok.com/ZS1/', 'tiktok'),
        ('https://www.tiktok.com/@a/video/1', 'tiktok'),
        ('https://www.threads.net/@a/post/B', 'threads'),
        ('https://www.threads.com/@a/post/B', 'threads'),
        ('https://threads.com/@a', 'threads'),
        ('https://uk.linkedin.com/in/a', 'linkedin'),
        ('https://www.linkedin.com/pulse/x-y', 'linkedin'),
        ('https://www.github.com/a/b', 'github'),
        ('https://gist.github.com/a/1', 'web'),
        ('https://raw.githubusercontent.com/a/b/main/x', 'web'),
        ('https://medium.com/@a/x', 'medium'),
        ('https://blog.medium.com/x', 'medium'),
        ('https://towardsdatascience.com/x-1234abcd5678', 'web'), // Medium custom domain: not detectable by host
        ('https://mobile.twitter.com/a', 'x'),
        ('https://twitter.com/a/status/1', 'x'),
        ('https://www.youtube-nocookie.com/embed/1', 'web'),
        ('https://example.com/', 'web'),
        ('https://127.0.0.1:8080/', 'web'),
      ]) {
        expect(LinkPreviewer.platformOf(Uri.parse(url)), platform, reason: url);
      }
    });

    // BUG: `h.endsWith('youtube.com')` (and tiktok/instagram/threads/linkedin) has no dot boundary, so
    // `notyoutube.com` is "youtube". Consequence: the private page URL is sent to youtube.com's oEmbed
    // and the watch page is requested for an unrelated site.
    test('lookalike hosts are not the real platforms', () {
      for (final h in [
        'notyoutube.com',
        'fake-tiktok.com',
        'myinstagram.com',
        'xthreads.net',
        'notlinkedin.com',
        'evilyoutube.com',
      ]) {
        expect(LinkPreviewer.platformOf(Uri.parse('https://$h/x')), 'web', reason: h);
      }
      for (final h in [
        'youtube.com.evil.io',
        'github.com.evil.io',
        'evilgithub.com',
        'evilmedium.com',
        'evil-twitter.com',
      ]) {
        expect(LinkPreviewer.platformOf(Uri.parse('https://$h/x')), 'web', reason: h);
      }
    });

    test('a lookalike host must not be sent to the real platform\'s oEmbed', () async {
      final net = Net((r) => http.Response('', 404));
      await prev('https://notyoutube.com/watch?v=secretdoc', (r) => http.Response('', 404), net: net);
      expect(net.contacted('www.youtube.com'), isFalse);
    });
  });

  group('youtubeId', () {
    test('every YouTube URL shape', () {
      String? id(String u) => DeepReader.youtubeId(Uri.parse(u));
      expect(id('https://youtu.be/abc?t=90'), 'abc');
      expect(id('https://youtu.be/abc/'), 'abc');
      expect(id('https://www.youtube.com/shorts/abc'), 'abc');
      expect(id('https://www.youtube.com/live/abc'), 'abc');
      expect(id('https://www.youtube.com/embed/abc'), 'abc');
      expect(id('https://music.youtube.com/watch?v=abc&list=RD1'), 'abc');
      expect(id('https://m.youtube.com/watch?v=abc'), 'abc');
      expect(id('https://youtube.com/watch?feature=share&v=abc'), 'abc');
      expect(id('https://youtu.be/'), isNull);
      expect(id('https://www.youtube.com/watch'), isNull);
      expect(id('https://www.youtube.com/watch?v='), isNull);
      expect(id('https://www.youtube.com/playlist?list=PL1'), isNull);
      expect(id('https://www.youtube.com/@chan'), isNull);
      expect(id('https://www.youtube.com/channel/UC123'), isNull);
    });
  });

  // BUG(low): `/shorts/` (or /live/, /embed/) with an empty id segment returns '' instead of null, so
  // DeepReader goes on to request /watch?v= (an empty id) from YouTube.
  test('youtubeId: an empty id segment is no id', () {
    expect(DeepReader.youtubeId(Uri.parse('https://www.youtube.com/shorts/')), isNull);
    expect(DeepReader.youtubeId(Uri.parse('https://www.youtube.com/embed/')), isNull);
  });

  group('kind per platform / path', () {
    Future<(String, String)> kindOf(String url) async {
      final p = await prev(url, (r) => http.Response('', 404));
      return (p.kind, p.title!);
    }

    test('YouTube, TikTok, Instagram, Threads, LinkedIn', () async {
      expect((await kindOf('https://www.youtube.com/watch?v=abc')).$1, 'video');
      expect((await kindOf('https://www.youtube.com/shorts/abc')).$1, 'video');
      expect((await kindOf('https://www.youtube.com/@chan')).$1, 'profile');
      expect((await kindOf('https://www.tiktok.com/@u/video/1')).$1, 'video');
      expect((await kindOf('https://www.tiktok.com/@u')).$1, 'profile');
      expect((await kindOf('https://www.instagram.com/reel/X/')).$1, 'video');
      expect((await kindOf('https://www.instagram.com/p/X/')).$1, 'post');
      expect((await kindOf('https://www.instagram.com/someone/reel/X/')).$1, 'video');
      expect((await kindOf('https://www.instagram.com/someone/p/X/')).$1, 'post');
      expect((await kindOf('https://www.instagram.com/nasa/')).$1, 'profile');
      expect((await kindOf('https://www.threads.net/@a/post/B')).$1, 'post');
      expect((await kindOf('https://www.threads.com/@a/post/B')).$1, 'post');
      expect((await kindOf('https://www.threads.net/@a')).$1, 'profile');
      expect((await kindOf('https://www.linkedin.com/pulse/some-article-by-x')).$1, 'article');
      expect((await kindOf('https://www.linkedin.com/posts/a_activity-123')).$1, 'post');
      expect((await kindOf('https://www.linkedin.com/feed/update/urn:li:activity:1/')).$1, 'post');
      expect((await kindOf('https://www.linkedin.com/in/someone')).$1, 'profile');
      expect((await kindOf('https://www.linkedin.com/company/google/')).$1, 'profile');
      expect((await kindOf('https://medium.com/@a/some-post-1234abcd5678')).$1, 'article');
    });

    // BUG: `path.contains('/reel')` also matches a profile called "reelgood" (and any /reel* handle).
    test('instagram profile whose name starts with "reel" is a profile, not a video', () async {
      expect((await kindOf('https://www.instagram.com/reelgood/')).$1, 'profile');
    });

    // BUG: TikTok photo posts (/@user/photo/ID) have no "/video/" so are classed "profile".
    test('TikTok photo post is not a profile', () async {
      expect((await kindOf('https://www.tiktok.com/@u/photo/123')).$1, isNot('profile'));
    });

    // BUG: YouTube channel/playlist URLs have no "/@" so every non-handle URL is a "video".
    test('YouTube channel and playlist are not videos', () async {
      expect((await kindOf('https://www.youtube.com/channel/UC123')).$1, isNot('video'));
      expect((await kindOf('https://www.youtube.com/playlist?list=PL1')).$1, isNot('video'));
    });

    // BUG: Threads' short form /t/<id> is a post but is classed "profile"; Instagram /tv/ (IGTV) is a video.
    test('Threads /t/ and Instagram /tv/ shapes', () async {
      expect((await kindOf('https://www.threads.net/t/CuXyz')).$1, 'post');
      expect((await kindOf('https://www.instagram.com/tv/CuXyz/')).$1, 'video');
    });

    // BUG: stories URLs (/stories/<user>/<id>) get the fallback title "@stories on Instagram".
    test('Instagram stories do not get "@stories" as the account', () async {
      final (_, title) = await kindOf('https://www.instagram.com/stories/nasa/3112345/');
      expect(title, isNot(contains('@stories')));
    });

    test('URL-only titles: reel vs post vs profile', () async {
      expect((await kindOf('https://www.instagram.com/reel/X/')).$2, 'Instagram video');
      expect((await kindOf('https://www.instagram.com/p/X/')).$2, 'Instagram post');
      expect((await kindOf('https://www.instagram.com/nasa/')).$2, '@nasa on Instagram');
      expect((await kindOf('https://www.tiktok.com/@scout/video/1')).$2, 'TikTok video by @scout');
      expect((await kindOf('https://www.threads.com/@a/post/B')).$2, 'Threads post by @a');
    });
  });

  // What the item is called when the site refuses (rate limit, bot check) or the phone is offline.
  group('URL-derived fallback titles', () {
    Future<String> offlineTitle(String url) async => (await prev(url, (r) => http.Response('', 403))).title!;

    // BUG(low): `_titleFromUrl` treats the repo segment as an opaque id when it is >= 6 chars without a dash
    // ("PhoneDots"), so github.com/Shashank2577/PhoneDots becomes "github.com · Shashank2577"; deep links
    // (/issues/1, /blob/main/README.md) become "1" / "README.md" - no repo name at all. Seen live from a
    // cloud IP, where api.github.com answered 403.
    test('GitHub links keep owner/repo', () async {
      expect(await offlineTitle('https://github.com/Shashank2577/PhoneDots'), contains('PhoneDots'));
      expect(await offlineTitle('https://github.com/flutter/flutter/issues/1'), contains('flutter/flutter'));
      expect(await offlineTitle('https://github.com/flutter/flutter/blob/main/README.md'), contains('flutter/flutter'));
    });

    // BUG(low): "@Google · @Google" - the handle is appended to a title that already is the handle.
    test('YouTube channel handle is not repeated', () async {
      final t = await offlineTitle('https://www.youtube.com/@Google');
      expect('@Google'.allMatches(t).length, 1, reason: t);
    });

    // BUG(low): every YouTube watch link that cannot be read is called "Watch" (the video id is dropped), so
    // several unreadable videos are indistinguishable in the list.
    test('unreadable YouTube links are told apart', () async {
      final a = await offlineTitle('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      final b = await offlineTitle('https://www.youtube.com/watch?v=aqz-KE-bpKQ');
      expect(a, isNot(b));
    });

    test('plain cases', () async {
      expect(await offlineTitle('https://example.com/'), 'example.com');
      expect(await offlineTitle('https://www.linkedin.com/in/someone-cool-123'), 'Someone cool 123');
      expect(await offlineTitle('https://medium.com/@karpathy/software-2-0-a64152b37c35'), 'Software 2 0 · @karpathy');
    });
  });

  // ───────────────────────── LinkPreviewer over a fake network ─────────────────────────
  group('short links', () {
    http.Response redirect(String to, [int code = 301]) => http.Response('', code, headers: {'location': to});

    test('vm.tiktok.com is expanded with HEAD, then the cleaned URL gets the oEmbed', () async {
      final net = Net((r) {
        if (r.url.host == 'vm.tiktok.com') {
          return redirect('https://www.tiktok.com/@scout/video/123?is_from_webapp=1&sender_device=pc');
        }
        if (r.url.path == '/oembed') return jsonOk({'title': 'Cute dogs', 'author_name': 'scout'});
        return http.Response('', 404);
      });
      final p = await prev('https://vm.tiktok.com/ZM1abc/', (r) => http.Response('', 500), net: net);
      expect(net.log.first.method, 'HEAD');
      expect(p.url, 'https://www.tiktok.com/@scout/video/123');
      expect((p.platform, p.kind, p.title, p.author, p.via), ('tiktok', 'video', 'Cute dogs', 'scout', 'oembed'));
      final oembed = net.log.firstWhere((r) => r.url.path == '/oembed');
      expect(oembed.url.queryParameters['url'], 'https://www.tiktok.com/@scout/video/123');
      expect(oembed.headers['User-Agent'], contains('PhoneDots'));
    });

    test('chains and relative redirects are followed; a loop gives up after five hops', () async {
      final hops = Net((r) {
        return switch (r.url.toString()) {
          'https://t.co/a' => redirect('https://bit.ly/b'),
          'https://bit.ly/b' => redirect('/c'),
          'https://bit.ly/c' => redirect('https://github.com/o/r?utm_source=x'),
          _ => http.Response('{}', 404),
        };
      });
      final p = await prev('https://t.co/a', (r) => http.Response('', 500), net: hops);
      expect(p.url, 'https://github.com/o/r');
      expect(p.platform, 'github');

      final loop = Net((r) => redirect('https://t.co/a'));
      final q = await prev('https://t.co/a', (r) => http.Response('', 500), net: loop);
      expect(loop.log.where((r) => r.method == 'HEAD'), hasLength(5));
      expect(q.title, isNotEmpty);
    });

    test('lnkd.in -> a LinkedIn post and link.medium.com -> a Medium article', () async {
      final net = Net((r) {
        if (r.url.host == 'lnkd.in') return redirect('https://www.linkedin.com/posts/a_activity-1?trk=x');
        if (r.url.host == 'link.medium.com') return redirect('https://medium.com/@a/slug-1234abcd5678?source=x');
        return http.Response('', 404);
      });
      final li = await prev('https://lnkd.in/abc', (r) => http.Response('', 500), net: net);
      expect((li.platform, li.kind, li.url), ('linkedin', 'post', 'https://www.linkedin.com/posts/a_activity-1'));
      final md = await prev('https://link.medium.com/xyz', (r) => http.Response('', 500), net: net);
      expect((md.platform, md.kind, md.url), ('medium', 'article', 'https://medium.com/@a/slug-1234abcd5678'));
    });

    test('a short link that does not redirect (200 or 405) stays as it is', () async {
      for (final code in [200, 405, 404]) {
        final p = await prev('https://vm.tiktok.com/ZM1/', (r) => http.Response('', code));
        expect(p.url, 'https://vm.tiktok.com/ZM1/');
        expect(p.title, isNotEmpty);
      }
    });

    // BUG: preview() calls _expand() *outside* its try/catch. A short link shared while offline (or a
    // timeout on the HEAD) makes preview() throw; Summarizer.process has no catch either, _enqueue
    // swallows it, and the item is left in "reading" forever (spinner that never stops).
    test('preview() does not throw when expanding a short link fails', () async {
      final net = Net((r) => throw const SocketException('offline'));
      await expectLater(prev('https://vm.tiktok.com/ZM1/', (r) => http.Response('', 500), net: net), completes);
    });

    test('preview() does not throw when the short-link HEAD times out', () async {
      final net = Net((r) => Completer<http.Response>().future);
      await expectLater(
        prev('https://bit.ly/x', (r) => http.Response('', 500), net: net, timeout: const Duration(milliseconds: 50)),
        completes,
      );
    });

    test('an offline TikTok short-link share ends up failed/needsModel, not spinning forever', () async {
      final rig = await Rig.make(handler: (r) => throw const SocketException('offline'));
      final item = await rig.share('https://vm.tiktok.com/ZM1abc/');
      expect(item.busy, isFalse, reason: 'stuck in ${item.status}');
    });
  });

  group('oEmbed failures', () {
    const yt = 'https://www.youtube.com/watch?v=abc';

    // BUG (policy): after the official endpoint answers 429/403/401 the previewer immediately requests the
    // watch page from the same site (`if (!p.rich) await _meta`), although the class docs promise it "never
    // retries around login walls or bot checks". Back off instead.
    test('a refusal from the oEmbed endpoint is not followed by a page scrape', () async {
      for (final code in [429, 403, 401]) {
        final net = Net((r) => http.Response('', code));
        final p = await prev(yt, (r) => http.Response('', 500), net: net);
        expect(net.log, hasLength(1), reason: 'oEmbed $code then ${net.urls}');
        expect(p.servedOpenly, isFalse, reason: '$code');
        expect(p.title, isNotEmpty);
      }
    });

    test('4xx/5xx without refusal semantics fall back to the page preview', () async {
      for (final code in [400, 404, 500, 503]) {
        final p = await prev(
          yt,
          (r) => r.url.path == '/oembed' ? http.Response('', code) : html('Real Title - YouTube'),
        );
        expect(p.title, 'Real Title', reason: '$code');
        expect(p.via, 'meta');
      }
    });

    test('timeouts on every request give a URL-derived title quickly and do not throw', () async {
      final sw = Stopwatch()..start();
      final net = Net((r) => Completer<http.Response>().future);
      final p = await prev(
        'https://www.tiktok.com/@scout/video/1',
        (r) => http.Response('', 500),
        net: net,
        timeout: const Duration(milliseconds: 50),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect((p.title, p.via, p.rich), ('TikTok video by @scout', 'url', false));
    });

    test('invalid / empty / wrong-shape JSON never throws', () async {
      for (final body in ['<html>nope</html>', '', '[]', 'null', '"str"', '{"title": 5}', '{"title": "   "}', '{']) {
        final p = await prev(yt, (r) => http.Response(body, 200));
        expect(p.title, isNotEmpty, reason: body);
      }
    });

    // BUG: one non-string field (author_name: 5) makes the cast throw, which discards the whole preview
    // including a perfectly good title.
    test('a non-string author does not discard the title', () async {
      final p = await prev(yt, (r) => jsonOk({'title': 'Good title', 'author_name': 5}));
      expect(p.title, 'Good title');
    });

    // BUG: bodyBytes are decoded with strict utf8.decode; invalid bytes in the JSON (a Latin-1 "e-acute")
    // throw and the whole preview is lost, unlike the HTML path which uses allowMalformed.
    test('invalid UTF-8 in oEmbed JSON still yields the title', () async {
      final bytes = <int>[...utf8.encode('{"title": "Caf'), 0xE9, ...utf8.encode('", "author_name": "x"}')];
      final p = await prev(yt, (r) => http.Response.bytes(bytes, 200));
      expect(p.title, startsWith('Caf'));
      expect(p.via, 'oembed');
    });

    test('a 10k-character title is shortened for display', () async {
      final p = await prev(yt, (r) => jsonOk({'title': 'x' * 10000}));
      expect(p.title!.length, lessThanOrEqualTo(160));
      expect(p.title, endsWith('…'));
    });

    test('invalid JSON does not make the preview claim rich data', () async {
      final p = await prev(yt, (r) => http.Response('<html>', 200));
      expect(p.rich, isFalse);
    });

    test('the request carries an honest user agent and no cookies or credentials', () async {
      final net = Net((r) => jsonOk({'title': 'T'}));
      await prev(yt, (r) => http.Response('', 500), net: net);
      for (final r in net.log) {
        expect(r.headers['User-Agent'], startsWith('PhoneDots/'));
        expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
        expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
      }
    });
  });

  group('page meta parsing', () {
    const url = 'https://blog.example.com/post';
    http.Response page(String body, {int code = 200, Map<String, String>? h}) =>
        http.Response(body, code, headers: {'content-type': 'text/html; charset=utf-8', ...?h});

    test('uppercase tags, single quotes, multi-line content, duplicates (first wins)', () async {
      final p = await prev(
        url,
        (r) => page(
          "<META PROPERTY='OG:TITLE' CONTENT='Shouting &amp; loud'>"
          '<meta property="og:title" content="second">'
          '<meta name="description" content="line one\nline two">',
        ),
      );
      expect(p.title, 'Shouting & loud');
      expect(p.description, 'line one\nline two');
    });

    test('empty og:title falls back to twitter:title, then <title>', () async {
      var p = await prev(
        url,
        (r) => page('<meta property="og:title" content=""><meta name="twitter:title" content="TW">'),
      );
      expect(p.title, 'TW');
      p = await prev(url, (r) => page('<title>\n  Only a title \n</title>'));
      expect(p.title, 'Only a title');
    });

    test('unterminated tags do not throw; <title> is still found', () async {
      final p = await prev(
        url,
        (r) => page('<html><meta property="og:title" content="Broken\n<title>Fallback</title>'),
      );
      expect(p.title, 'Fallback');
    });

    // BUG: the tag regex ends at the first `>` even inside a quoted attribute, so an unescaped `>` in a
    // title ("Rust -> Go") loses og:title (the attribute regex then finds no closing quote).
    test('a literal > inside an attribute value', () async {
      final p = await prev(url, (r) => page('<meta property="og:title" content="Rust -> Go migration">'));
      expect(p.title, 'Rust -> Go migration');
    });

    test('numeric and hex entities, emoji, nbsp', () async {
      final p = await prev(url, (r) => page('<meta property="og:title" content="It&#8217;s &#x1F600; fun&nbsp;time">'));
      expect(p.title, 'It’s 😀 fun time');
    });

    // BUG: an out-of-range numeric entity (&#99999999;) makes String.fromCharCode throw RangeError; it
    // escapes parseMeta, so the *entire* preview (valid description, image, other title tags) is dropped.
    test('one invalid entity does not drop the page preview', () async {
      final p = await prev(
        url,
        (r) => page(
          '<meta property="og:title" content="Fine title &#99999999; end">'
          '<meta property="og:description" content="ok">',
        ),
      );
      expect(p.title, startsWith('Fine title'));
      expect(p.rich, isTrue);
    });

    // BUG: the response charset is ignored; ISO-8859-1 pages decode with U+FFFD in place of e-acute.
    test('a page served as ISO-8859-1', () async {
      final bytes = <int>[
        ...latin1.encode('<meta property="og:title" content="Caf'),
        0xE9,
        ...latin1.encode(' menu">'),
      ];
      final p = await prev(
        url,
        (r) => http.Response.bytes(bytes, 200, headers: {'content-type': 'text/html; charset=iso-8859-1'}),
      );
      expect(p.title, 'Café menu');
    });

    test('a 6 MB page is parsed from its head quickly', () async {
      final big = '<meta property="og:title" content="Big page">${'<p>filler text</p>' * 350000}';
      final sw = Stopwatch()..start();
      final p = await prev(url, (r) => page(big));
      expect(p.title, 'Big page');
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a title only after 400 kB of markup is not found but does not crash', () async {
      final p = await prev(url, (r) => page('${'<div>x</div>' * 50000}<meta property="og:title" content="Too late">'));
      expect(p.title, isNotEmpty);
    });

    test('binary body (PDF) is not decoded into a bogus title', () async {
      final p = await prev(
        'https://example.com/report.pdf',
        (r) => http.Response.bytes(
          [0x25, 0x50, 0x44, 0x46, 0xFF, 0xFE, 0x00],
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      );
      expect(p.title, 'Report.pdf');
      expect(p.rich, isFalse);
    });

    // BUG: `<meta ` repeated with no closing `>` makes `<meta\b[^>]*>` quadratic (every start scans to the
    // end of the 400 kB head): a hostile or truncated page can freeze the UI isolate. Here 12k tags (72 kB)
    // are used; the real cap (400 kB) is ~30x worse (quadratic).
    test('pathological unterminated <meta tags are parsed in bounded time', () {
      final sw = Stopwatch()..start();
      LinkPreviewer.parseMeta('<meta ' * 12000);
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('login walls and generic titles', () {
    const url = 'https://blog.example.com/post';
    Future<LinkPreview> withTitle(String t, {String u = url}) => prev(u, (r) => html(t));

    test('known walls are not titles', () async {
      for (final t in [
        'Instagram',
        'Login • Instagram',
        'Threads • Log in',
        'TikTok - Make Your Day',
        'Sign Up | LinkedIn',
        'Just a moment...',
        'Attention Required! | Cloudflare',
        'Access Denied',
      ]) {
        final p = await withTitle(t);
        expect(p.rich, isFalse, reason: t);
        expect(p.walled, isTrue, reason: t);
        expect(p.servedOpenly, isFalse, reason: t);
      }
    });

    // BUG: LinkedIn's real logged-out title ("LinkedIn Login, Sign in | LinkedIn") is not in the generic
    // list, so it is shown as the item title and the page counts as "served openly" (web reader allowed).
    test('LinkedIn login wall title', () async {
      final p = await withTitle('LinkedIn Login, Sign in | LinkedIn', u: 'https://www.linkedin.com/posts/a_activity-1');
      expect(p.rich, isFalse);
    });

    // BUG: any title *starting* with "log in"/"sign in" is treated as a wall, so real articles are lost.
    test('legit titles that merely start with "Sign in" / "Log in" are kept', () async {
      for (final t in ['Sign in with Apple: a developer guide', 'Log in to your Raspberry Pi over SSH']) {
        final p = await withTitle(t);
        expect(p.rich, isTrue, reason: t);
      }
    });

    // BUG(low): none of these soft error pages (HTTP 200) are recognised as error pages.
    test('soft error pages that answer 200', () async {
      for (final t in ['404 Not Found', 'Too Many Requests', 'Verify you are human', '403 Forbidden']) {
        final p = await withTitle(t);
        expect(p.rich, isFalse, reason: t);
      }
    });

    test('401/403/429/999/503 mean not served openly, whatever the body says', () async {
      for (final code in [401, 403, 429, 999, 503]) {
        final p = await prev(url, (r) => http.Response('<title>Fine</title>', code));
        expect(p.servedOpenly, isFalse, reason: '$code');
        expect(p.rich, isFalse);
      }
    });
  });

  group('platform-specific previews', () {
    test('Threads .net and .com both use the tokenless oEmbed and become a post', () async {
      for (final host in ['www.threads.net', 'www.threads.com', 'threads.com']) {
        final net = Net(
          (r) => jsonOk({
            'author_name': 'ana',
            'html': '<blockquote><p>First line<br>second &amp; third</p><a>View on Threads</a></blockquote>',
          }),
        );
        final p = await prev('https://$host/@ana/post/ABC?xmt=1', (r) => http.Response('', 500), net: net);
        expect(net.log.single.url.host, 'graph.threads.com');
        expect(net.log.single.url.queryParameters['url'], 'https://$host/@ana/post/ABC');
        expect(p.body, 'First line\nsecond & third');
        expect((p.kind, p.via, p.bodyFrom), ('post', 'oembed', 'Threads embed'));
        expect(p.title, 'ana: First line');
      }
    });

    test('Threads/X embeds with empty html or no <p> fall back sensibly', () async {
      var p = await prev(
        'https://www.threads.net/@ana/post/ABC',
        (r) =>
            r.url.host == 'graph.threads.com' ? jsonOk({'author_name': 'ana', 'html': ''}) : html('ana on Threads: hi'),
      );
      expect(p.body, isNull);
      expect(p.title, 'ana on Threads: hi'); // went on to the page preview

      p = await prev('https://x.com/a/status/1', (r) => jsonOk({'html': 'plain text only, no paragraph'}));
      expect(p.body, 'plain text only, no paragraph');
    });

    test('X: only /status/ links ask publish.twitter.com; twitter.com and mobile hosts too', () async {
      final net = Net((r) => jsonOk({'author_name': 'a', 'html': '<p>hi</p>'}));
      await prev('https://twitter.com/a/status/1', (r) => http.Response('', 500), net: net);
      await prev('https://mobile.twitter.com/a/status/2', (r) => http.Response('', 500), net: net);
      expect(net.log.where((r) => r.url.host == 'publish.twitter.com'), hasLength(2));
      expect(net.log.first.url.queryParameters['dnt'], 'true');
    });

    test('Instagram login wall: no fake caption, URL-derived title, never "rich"', () async {
      for (final path in ['reel/X/', 'p/X/', 'stories/nasa/311/']) {
        final p = await prev('https://www.instagram.com/$path', (r) => html('Login • Instagram'));
        final deep = DeepReader(client: Net((r) => http.Response('', 404)).client);
        await deep.read(p);
        expect(p.body, isNull, reason: path);
        expect(p.rich, isFalse);
      }
    });

    test('Instagram public reel: caption lifted, quotes and trailing dot handled', () async {
      final p = await prev(
        'https://www.instagram.com/reel/X/',
        (r) => html(
          'Chef on Instagram',
          desc: '1,024 likes, 12 comments - chef.ana on May 1, 2026: &quot;Line 1\nLine 2&quot;.',
        ),
      );
      await DeepReader(client: Net((r) => http.Response('', 404)).client).read(p);
      expect(p.body, 'Line 1\nLine 2');
      expect(p.author, 'chef.ana');
    });

    test('LinkedIn post: description becomes the body', () async {
      final p = await prev(
        'https://www.linkedin.com/posts/a_activity-1',
        (r) => html('A post | LinkedIn', desc: 'Hello network'),
      );
      await DeepReader(client: Net((r) => http.Response('', 404)).client).read(p);
      expect((p.title, p.body, p.bodyFrom), ('A post', 'Hello network', 'LinkedIn preview'));
    });

    test('LinkedIn 999 (its bot answer) is not read around', () async {
      final net = Net((r) => http.Response('', 999));
      final p = await prev('https://www.linkedin.com/posts/a_activity-1', (r) => http.Response('', 500), net: net);
      expect(p.servedOpenly, isFalse);
    });

    test('GitHub deep links all resolve to the owner/repo API call', () async {
      for (final path in [
        'o/r/blob/main/README.md',
        'o/r/issues/12',
        'o/r/pull/3/files',
        'o/r/tree/dev/src',
        'o/r/wiki',
        'o/r/',
        'o/r?tab=readme-ov-file',
      ]) {
        final net = Net(
          (r) => jsonOk({
            'full_name': 'o/r',
            'description': 'D',
            'owner': {'login': 'o'},
          }),
        );
        final p = await prev('https://github.com/$path', (r) => http.Response('', 500), net: net);
        expect(net.log.single.url.path, '/repos/o/r', reason: path);
        expect((p.title, p.kind, p.via), ('o/r', 'repo', 'api'), reason: path);
      }
    });

    test('GitHub: user/org pages and non-repo paths fall back to the page preview', () async {
      var net = Net((r) => r.url.host == 'api.github.com' ? http.Response('', 404) : html('GitHub - o: profile'));
      var p = await prev('https://github.com/o', (r) => http.Response('', 500), net: net);
      expect(net.contacted('api.github.com'), isFalse);
      expect(p.title, 'GitHub - o: profile');
      net = Net((r) => r.url.host == 'api.github.com' ? http.Response('', 404) : html('Orgs page'));
      p = await prev('https://github.com/orgs/o/people', (r) => http.Response('', 500), net: net);
      expect(p.title, 'Orgs page');
    });

    // BUG (policy): DeepReader.read goes on to /repos/o/r/readme after the same API refused the metadata
    // call with 403/429 (unauthenticated rate limit), contradicting "nothing here retries around a refusal".
    test('GitHub API rate-limit refusal is not retried on the README endpoint', () async {
      final net = Net((r) => http.Response('rate limited', 403));
      final p = await LinkPreviewer(client: net.client).preview('https://github.com/o/r');
      await DeepReader(client: net.client).read(p);
      expect(net.urls.where((u) => u.contains('/readme')), isEmpty);
    });

    test('GitHub README: empty / badges-only is ignored; a 200 kB README is capped', () async {
      var net = Net(
        (r) => r.url.path.endsWith('/readme') ? http.Response('[![CI](a)](b)\n![x](y)\n', 200) : http.Response('', 404),
      );
      var p = LinkPreview(url: 'https://github.com/o/r', platform: 'github');
      await DeepReader(client: net.client).read(p);
      expect(p.body, isNull);
      net = Net((r) => http.Response('word ' * 40000, 200));
      p = LinkPreview(url: 'https://github.com/o/r', platform: 'github');
      await DeepReader(client: net.client).read(p);
      expect(p.body!.length, DeepReader.maxBody + 1);
      expect(p.body, endsWith('…'));
    });

    test('Medium: feed URL per shape, post id only from a hex tail', () {
      String? feed(String u) => DeepReader.mediumFeed(Uri.parse(u))?.toString();
      expect(feed('https://medium.com/@a/some-post-1234abcd5678'), 'https://medium.com/feed/@a');
      expect(feed('https://medium.com/pub/some-post-1234abcd5678'), 'https://medium.com/feed/pub');
      expect(feed('https://a.medium.com/some-post-1234abcd5678'), 'https://medium.com/feed/@a');
      expect(feed('https://medium.com/p/1234abcd5678'), isNull);
      expect(feed('https://medium.com/'), isNull);
      expect(feed('https://towardsdatascience.com/x-1234abcd5678'), isNull); // custom domain: no feed
      expect(
        DeepReader.mediumPostId(Uri.parse('https://medium.com/@a/some-post-1234abcd5678?source=x')),
        '1234abcd5678',
      );
      expect(DeepReader.mediumPostId(Uri.parse('https://medium.com/@a/')), isNull);
      expect(DeepReader.mediumPostId(Uri.parse('https://medium.com/@a/no-id-here')), isNull);
    });

    test('Medium custom domain is a plain web link: no feed request', () async {
      final net = Net((r) => html('Custom domain post'));
      final p = await prev('https://towardsdatascience.com/x-1234abcd5678', (r) => http.Response('', 500), net: net);
      expect(p.platform, 'web');
      await DeepReader(client: net.client).read(p);
      expect(net.urls.where((u) => u.contains('/feed/')), isEmpty);
    });

    test('Medium RSS: wrong id, refusal, malformed XML and empty content all leave body null', () async {
      const id = '1234abcd5678';
      for (final feedResponse in [
        http.Response(
          '<rss><channel><item><guid>https://medium.com/p/ffffffffffff</guid>'
          '<content:encoded><![CDATA[<p>x</p>]]></content:encoded></item></channel></rss>',
          200,
        ),
        http.Response('', 429),
        http.Response('<rss><item><guid>https://medium.com/p/$id', 200),
        http.Response('<item><guid>https://medium.com/p/$id</guid></item>', 200),
        http.Response(
          '<item><guid>https://medium.com/p/$id</guid><content:encoded><![CDATA[   ]]></content:encoded></item>',
          200,
        ),
      ]) {
        final net = Net((r) => r.url.path.startsWith('/feed/') ? feedResponse : html('Post | Medium'));
        final p = await prev('https://medium.com/@a/post-$id', (r) => http.Response('', 500), net: net);
        await DeepReader(client: net.client).read(p);
        expect(p.body, isNull, reason: '${feedResponse.statusCode} ${feedResponse.body}');
      }
    });

    test('YouTube watch page: consent wall, malformed escapes, missing fields, unicode', () async {
      Future<LinkPreview> deepOf(String page, {int code = 200}) async {
        final net = Net((r) => r.url.path == '/watch' ? http.Response(page, code) : http.Response('', 404));
        final p = LinkPreview(url: 'https://www.youtube.com/watch?v=abc', platform: 'youtube', kind: 'video');
        await DeepReader(client: net.client).read(p);
        return p;
      }

      expect((await deepOf('<html>Before you continue to YouTube</html>')).body, isNull);
      expect((await deepOf('"shortDescription":"ok"', code: 429)).body, isNull);
      expect((await deepOf('"shortDescription":"bad \\q escape"')).body, isNull);
      final p = await deepOf('"shortDescription":"caf\\u00e9 \\ud83d\\ude00 \\u0026 more"');
      expect(p.body, 'café 😀 & more'); // no length / tags lines when YouTube sent none
      expect((await deepOf('"shortDescription":""')).body, isNull);
    });

    test('YouTube Data API: key never reaches the ledger; quota error falls back to the page', () async {
      final rig = await Rig.make(
        youtubeKey: 'SECRETKEY123',
        handler: (r) {
          if (r.url.host == 'www.googleapis.com') return http.Response('{"error":{"code":403}}', 403);
          if (r.url.path == '/oembed') return jsonOk({'title': 'T'});
          if (r.url.path == '/watch') return http.Response('"shortDescription":"from the page"', 200);
          return http.Response('', 404);
        },
      );
      final item = await rig.share('https://www.youtube.com/watch?v=abc');
      expect(item.body, contains('from the page'));
      expect(rig.ledger.entries.map((e) => e.detail).join('\n'), isNot(contains('SECRETKEY123')));
      expect(rig.net.urls.where((u) => u.contains('googleapis')), hasLength(1));
    });
  });

  // ───────────────────────── Web reader (Jina) ─────────────────────────
  group('web reader is only for pages served openly', () {
    Future<(Rig, SavedItem)> run(String url, Handler h, {bool on = true, String jinaKey = ''}) async {
      final rig = await Rig.make(handler: h, webReader: on, jinaKey: jinaKey);
      final item = await rig.share(url);
      return (rig, item);
    }

    test('never after 401 / 403 / 429 / 999 / 5xx', () async {
      for (final code in [401, 403, 429, 999, 500, 503]) {
        final (rig, item) = await run('https://blog.example.com/post', (r) => http.Response('', code));
        expect(rig.net.contacted('r.jina.ai'), isFalse, reason: '$code');
        expect(item.sources, isNot(contains('Jina Reader')));
        expect(item.status, SavedStatus.done);
      }
    });

    test('never after a login wall or bot check that answers 200', () async {
      for (final t in [
        'Log in to continue',
        'Just a moment...',
        'Attention Required! | Cloudflare',
        'Login • Instagram',
        'Access Denied',
      ]) {
        final (rig, _) = await run('https://blog.example.com/post', (r) => html(t));
        expect(rig.net.contacted('r.jina.ai'), isFalse, reason: t);
      }
    });

    test('never when the site refused the *official* channel (social platforms)', () async {
      for (final url in [
        'https://www.tiktok.com/@a/video/1',
        'https://www.instagram.com/reel/X/',
        'https://www.threads.net/@a/post/B',
        'https://www.linkedin.com/posts/a_activity-1',
        'https://x.com/a/status/1',
      ]) {
        final (rig, _) = await run(url, (r) => r.url.host == 'r.jina.ai' ? jina() : http.Response('', 429));
        expect(rig.net.contacted('r.jina.ai'), isFalse, reason: url);
      }
    });

    // BUG: servedOpenly only looks at the preview request. YouTube's oEmbed answers 200 while the watch
    // page is a LOGIN_REQUIRED bot check; DeepReader correctly refuses to read it, but Summarizer then
    // sends the very same URL to Jina, i.e. uses the reader to get past the bot check.
    test('YouTube bot-check page (oEmbed 200, watch LOGIN_REQUIRED) is not handed to the reader', () async {
      final (rig, item) = await run('https://www.youtube.com/watch?v=abc', (r) {
        if (r.url.host == 'r.jina.ai') return jina();
        if (r.url.path == '/oembed') return jsonOk({'title': 'T', 'author_name': 'A'});
        if (r.url.path == '/watch') {
          return http.Response(
            '"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you are not a bot"}',
            200,
          );
        }
        return http.Response('', 404);
      });
      expect(rig.net.contacted('r.jina.ai'), isFalse);
      expect(item.sources, isNot(contains('Jina Reader')));
    });

    // BUG: same root cause for Medium: page preview 200, but the official RSS feed refuses (429/403,
    // Cloudflare); the reader is then asked for the (possibly member-only) article.
    test('Medium RSS refusal is not worked around with the reader', () async {
      final (rig, _) = await run('https://medium.com/@a/post-1234abcd5678', (r) {
        if (r.url.host == 'r.jina.ai') return jina();
        if (r.url.path.startsWith('/feed/')) return http.Response('', 429);
        return html('Post | Medium');
      });
      expect(rig.net.contacted('r.jina.ai'), isFalse);
    });

    // BUG (same): GitHub API 403/429 rate-limit, then the repo page 200 -> reader.
    test('GitHub API refusal is not worked around with the reader', () async {
      final (rig, _) = await run('https://github.com/o/r', (r) {
        if (r.url.host == 'r.jina.ai') return jina();
        if (r.url.host == 'api.github.com') return http.Response('rate limit', 403);
        return html('GitHub - o/r');
      });
      expect(rig.net.contacted('r.jina.ai'), isFalse);
    });

    test('used for an open, thin page; key is sent only as a Bearer header; ledger notes it', () async {
      final (rig, item) = await run(
        'https://blog.example.com/flutter',
        (r) => r.url.host == 'r.jina.ai' ? jina() : html('Flutter speed', desc: 'Tips.'),
        jinaKey: 'JINAKEY',
      );
      final req = rig.net.log.firstWhere((r) => r.url.host == 'r.jina.ai');
      expect(req.url.toString(), 'https://r.jina.ai/https://blog.example.com/flutter');
      expect(req.headers['Authorization'], 'Bearer JINAKEY');
      expect(item.sources, contains('Jina Reader'));
      expect(item.body, contains('Flutter performance'));
      expect(rig.netLines.any((l) => l.contains('Jina Reader')), isTrue);
      expect(rig.ledger.entries.map((e) => e.detail).join(), isNot(contains('JINAKEY')));
    });

    test('not used when off (default), when the description is already long, or when there is a body', () async {
      http.Response h(http.Request r) => r.url.host == 'r.jina.ai' ? jina() : html('T', desc: 'd' * 250);
      var (rig, _) = await run('https://blog.example.com/a', h, on: false);
      expect(rig.net.contacted('r.jina.ai'), isFalse);
      (rig, _) = await run('https://blog.example.com/a', h);
      expect(rig.net.contacted('r.jina.ai'), isFalse);
      (rig, _) = await run('https://www.threads.net/@a/post/B', (r) {
        if (r.url.host == 'graph.threads.com') return jsonOk({'author_name': 'a', 'html': '<p>post text</p>'});
        return r.url.host == 'r.jina.ai' ? jina() : http.Response('', 404);
      });
      expect(rig.net.contacted('r.jina.ai'), isFalse);
    });

    test('WebReader.looksBlocked / clean', () {
      expect(WebReader.looksBlocked('Verify you are human by completing the action below.'), isTrue);
      expect(WebReader.looksBlocked('Please enable JavaScript to continue'), isTrue);
      expect(WebReader.looksBlocked('Sign in to read. ${'x ' * 500}'), isFalse); // long page that mentions sign in
      expect(WebReader.clean('no header at all\n\n\n\nsecond'), 'no header at all\n\nsecond');
    });

    // BUG: looksBlocked only knows "log in / sign in / just a moment / verify you are human / enable
    // javascript". Typical block pages that Jina relays with HTTP 200 slip through and get summarised as
    // if they were the article.
    test('common block-page texts relayed by the reader are rejected', () async {
      const blocks = [
        'Access Denied. You don\'t have permission to access "http://www.example.com/article" on this server. Reference #18.4a2b3c.1700000000.abc',
        'Warning: Target URL returned error 403: Forbidden. Sorry, you have been blocked. You are unable to access example.com because of a security rule.',
        'Please complete the security check to access this page. Checking your browser before accessing the site. Cloudflare Ray ID: abc123',
        'Our systems have detected unusual traffic from your computer network. Please solve this CAPTCHA to continue.',
      ];
      for (final b in blocks) {
        final client = MockClient((r) async => http.Response('Title: x\nMarkdown Content:\n$b', 200));
        expect(await WebReader(client: client).read('https://example.com/a'), isNull, reason: b);
      }
    });

    test('short text, non-200 and thrown errors read as null', () async {
      expect(
        await WebReader(client: MockClient((r) async => http.Response('tiny', 200))).read('https://e.com'),
        isNull,
      );
      expect(
        await WebReader(client: MockClient((r) async => http.Response('x' * 2000, 429))).read('https://e.com'),
        isNull,
      );
      expect(
        await WebReader(client: MockClient((r) async => throw const SocketException('x'))).read('https://e.com'),
        isNull,
      );
      final capped = await WebReader(client: MockClient((r) async => http.Response('word ' * 5000, 200)))
          .read('https://e.com', maxChars: 100);
      expect(capped!.length, 101);
    });
  });

  // ───────────────────────── ledger ─────────────────────────
  group('privacy ledger records every network read', () {
    Future<void> expectEveryHostLogged(String url, Handler h, {bool webReader = false}) async {
      final rig = await Rig.make(handler: h, webReader: webReader);
      await rig.share(url);
      final lines = rig.netLines.join('\n');
      for (final host in rig.net.hosts) {
        // The reader is named by product ("Asked Jina Reader to read ..."), not by host.
        expect(
          lines,
          contains(host == 'r.jina.ai' ? 'Jina' : host),
          reason: 'contacted $host but the ledger says:\n$lines',
        );
      }
    }

    test('YouTube (oEmbed + page + cover)', () async {
      await expectEveryHostLogged('https://youtu.be/abc', (r) {
        if (r.url.path == '/oembed') {
          return jsonOk({'title': 'T', 'thumbnail_url': 'https://i.ytimg.com/vi/abc/hq.jpg'});
        }
        if (r.url.path == '/watch') return http.Response('"shortDescription":"d"', 200);
        if (r.url.host == 'i.ytimg.com') return http.Response('x', 200, headers: {'content-type': 'image/jpeg'});
        return http.Response('', 404);
      });
    });

    test('plain web page (page + reader + cover)', () async {
      await expectEveryHostLogged('https://blog.example.com/p', (r) {
        if (r.url.host == 'r.jina.ai') return jina();
        if (r.url.host == 'cdn.example.com') return http.Response('x', 200, headers: {'content-type': 'image/png'});
        return http.Response(
          '<meta property="og:title" content="T"><meta property="og:image" content="https://cdn.example.com/c.png">',
          200,
        );
      }, webReader: true);
    });

    test('Medium (page + RSS feed)', () async {
      await expectEveryHostLogged('https://medium.com/@a/post-1234abcd5678', (r) => html('Post | Medium'));
    });

    // BUG: the preview line names only the host of the *shared* URL ("Read the preview of threads.net" /
    // "github.com" / "vm.tiktok.com" / "x.com"), but the requests go to graph.threads.com,
    // publish.twitter.com, api.github.com and www.tiktok.com. Those hosts never appear in the ledger.
    test('Threads: graph.threads.com is logged', () async {
      await expectEveryHostLogged(
        'https://www.threads.net/@a/post/B',
        (r) => jsonOk({'author_name': 'a', 'html': '<p>hi</p>'}),
      );
    });

    test('X: publish.twitter.com is logged', () async {
      await expectEveryHostLogged('https://x.com/a/status/1', (r) => jsonOk({'author_name': 'a', 'html': '<p>hi</p>'}));
    });

    test('TikTok short link: both the short-link host and www.tiktok.com are logged', () async {
      await expectEveryHostLogged('https://vm.tiktok.com/ZM1/', (r) {
        if (r.url.host == 'vm.tiktok.com') {
          return http.Response('', 301, headers: {'location': 'https://www.tiktok.com/@a/video/1'});
        }
        return jsonOk({'title': 'T'});
      });
    });

    test('GitHub: api.github.com is logged', () async {
      await expectEveryHostLogged(
        'https://github.com/o/r',
        (r) => r.url.path.endsWith('/readme') ? http.Response('# R', 200) : jsonOk({'full_name': 'o/r'}),
      );
    });

    test('Instagram login wall (page only)', () async {
      await expectEveryHostLogged('https://www.instagram.com/reel/X/', (r) => html('Login • Instagram'));
    });

    // BUG: the cover download is logged only after a response arrives; a failed/timed-out download made
    // a request but leaves no ledger line.
    test('a cover download that fails still leaves a ledger line', () async {
      final rig = await Rig.make(
        handler: (r) {
          if (r.url.host == 'cdn.example.com') throw const SocketException('reset');
          return http.Response(
            '<meta property="og:title" content="T"><meta property="og:image" content="https://cdn.example.com/c.png">',
            200,
          );
        },
      );
      await rig.share('https://blog.example.com/p');
      expect(rig.net.contacted('cdn.example.com'), isTrue);
      expect(rig.netLines.join('\n'), contains('cdn.example.com'));
    });

    test('with "read links" off nothing is fetched and nothing network is logged', () async {
      final rig = await Rig.make(readLinks: false, handler: (r) => html('T'));
      final item = await rig.share('Look https://youtu.be/abc', subject: 'Great video');
      expect(rig.net.log, isEmpty);
      expect(rig.netLines, isEmpty);
      expect(item.title, 'Great video');
      expect(item.status, SavedStatus.done);
    });

    test('ledger lines persist across a restart', () async {
      final rig = await Rig.make(handler: (r) => html('T'));
      await rig.share('https://blog.example.com/p');
      final again = Ledger(rig.store);
      await again.load();
      expect(again.entries.where((e) => e.network), isNotEmpty);
    });
  });

  // ───────────────────────── Summarizer: share intake ─────────────────────────
  group('addShare', () {
    test('caption is the text minus the link; only a link -> empty caption', () async {
      final rig = await Rig.make(autoSummarise: false);
      var item = await rig.sum.addShare(text: 'Look   at this https://youtu.be/abc?si=1 wow');
      expect((item.sharedText, item.url), ('Look at this wow', 'https://youtu.be/abc'));
      item = await rig.sum.addShare(text: 'https://youtu.be/abc');
      expect((item.sharedText, item.url, item.platform, item.kind), ('', 'https://youtu.be/abc', 'youtube', 'link'));
    });

    test('subject-only share: the link in the subject is found', () async {
      final rig = await Rig.make(autoSummarise: false);
      final item = await rig.sum.addShare(subject: 'Great video https://youtu.be/abc');
      expect(item.url, 'https://youtu.be/abc');
      expect(item.sharedText, '');
    });

    test('whitespace-only subject is dropped', () async {
      final rig = await Rig.make(autoSummarise: false);
      final item = await rig.sum.addShare(text: 'https://example.com/a', subject: '   ');
      expect(item.subject, isNull);
    });

    // BUG: every URL is cut out of the caption but only the first is kept as `url`, so a second link in
    // the same share ("compare A and B") is silently lost from the saved item.
    test('a second link in the share text is not lost', () async {
      final rig = await Rig.make(autoSummarise: false);
      final item = await rig.sum.addShare(text: 'Compare https://a.example.com/1 and https://b.example.com/2');
      expect(item.url, 'https://a.example.com/1');
      final kept = '${item.sharedText} ${item.description ?? ''} ${item.body ?? ''}';
      expect(kept, contains('b.example.com/2'));
    });

    test('screenshot, video and document shares', () async {
      final rig = await Rig.make(autoSummarise: false);
      var item = await rig.sum.addShare(
        files: [
          {'path': '/t/s.png', 'name': 's.png', 'kind': 'image'},
        ],
      );
      expect((item.platform, item.kind, item.imagePath, item.url), ('screenshot', 'image', '/t/s.png', null));
      item = await rig.sum.addShare(
        files: [
          {'path': '/t/v.mp4', 'name': 'v.mp4', 'kind': 'audio'},
        ],
      );
      expect((item.platform, item.kind), ('file', 'audio'));
      item = await rig.sum.addShare(
        files: [
          {'path': '/t/d.pdf', 'name': 'd.pdf', 'kind': 'document'},
        ],
      );
      expect((item.platform, item.kind), ('file', 'document'));
      item = await rig.sum.addShare(text: 'only a caption, no link');
      expect((item.platform, item.kind), ('file', 'note'));
    });

    test('auto-summarise off: kept as "needs a summary", nothing asked, nothing fetched', () async {
      final rig = await Rig.make(autoSummarise: false, handler: (r) => html('T'));
      final item = await rig.sum.addShare(text: 'https://example.com/a');
      await rig.settle();
      expect(item.status, SavedStatus.needsModel);
      expect(rig.asks, isEmpty);
      expect(rig.net.log, isEmpty);
      await rig.sum.resummarise(item);
      expect(item.status, SavedStatus.done);
    });
  });

  group('AppServices.receiveShare routing', () {
    Future<AppServices> services() =>
        AppServices.create(store: MemoryJsonStore(), platform: 'demo', linkClient: Net((r) => html('T')).client);

    test('plain text -> chat intake; link -> saved; attachment only -> saved; text + attachment -> saved', () async {
      final s = await services();
      await s.receiveShare(text: 'remind me to buy milk');
      expect(s.intake.value?.text, 'remind me to buy milk');
      expect(s.saved.items, isEmpty);
      s.intake.value = null;

      await s.receiveShare(text: 'https://example.com/a');
      expect(s.saved.items, hasLength(1));
      expect(s.intake.value, isNull);

      await s.receiveShare(
        attachments: [Attachment(id: 'a1', kind: 'image', path: '/t/s.png', name: 's.png')],
      );
      expect(s.saved.items, hasLength(2));
      expect(s.saved.items.first.platform, 'screenshot');

      await s.receiveShare(
        text: 'caption words',
        attachments: [Attachment(id: 'a1', kind: 'audio', path: '/t/v.mp4', name: 'v.mp4')],
      );
      expect(s.saved.items, hasLength(3));
      expect(s.saved.items.first.sharedText, 'caption words');
    });

    test('non-web schemes in a share are plain text for the chat', () async {
      final s = await services();
      await s.receiveShare(text: 'mailto:a@b.com');
      expect(s.saved.items, isEmpty);
      expect(s.intake.value?.text, 'mailto:a@b.com');
    });

    test('a link only in the subject is still saved', () async {
      final s = await services();
      await s.receiveShare(subject: 'Neat https://example.com/a');
      expect(s.saved.items, hasLength(1));
      expect(s.savedArrived.value, s.saved.items.first.id);
    });

    // BUG: the subject never reaches the intake, so a subject-only plain share opens an empty chat.
    test('a subject-only plain share is not dropped', () async {
      final s = await services();
      await s.receiveShare(subject: 'Recipe idea for tonight');
      expect(s.intake.value?.text, contains('Recipe idea'));
    });

    // BUG: the "save a link" sheet (saved_screen.dart `_addLink`) passes what the user typed straight to
    // receiveShare. A bare domain ("example.com/article") or plain words are not "links" to findUrls, so they
    // are routed to the *chat* intake: the sheet closes, the Saved tab shows nothing, and the text is silently
    // parked in the hidden chat box. The explicit "save a link" box should accept any host (or say why not).
    test('typing a bare domain into "save a link" saves it', () async {
      final s = await services();
      await s.receiveShare(text: 'example.com/article');
      expect(s.saved.items, hasLength(1), reason: 'went to chat intake instead: ${s.intake.value?.text}');
    });

    // BUG: findUrls throws FormatException on `http://[::1`, so receiveShare throws instead of falling
    // back to the chat.
    test('a malformed link does not make receiveShare throw', () async {
      final s = await services();
      await expectLater(s.receiveShare(text: 'http://[::1'), completes);
    });

    test('arrival is announced once per share, with the new item id', () async {
      final s = await services();
      final seen = <String?>[];
      s.savedArrived.addListener(() => seen.add(s.savedArrived.value));
      await s.receiveShare(text: 'https://example.com/a');
      await s.receiveShare(text: 'https://example.com/b');
      expect(seen, hasLength(2));
      expect(seen.toSet(), hasLength(2));
      expect(seen.first, s.saved.items.last.id);
    });
  });

  // ───────────────────────── Summarizer: model replies ─────────────────────────
  group('model reply variants', () {
    SavedItem fresh() => SavedItem(id: '1', created: DateTime(2026), sources: ['caption']);

    test('fenced JSON, prose before, ```json fences, CRLF', () {
      for (final raw in [
        '```json\n{"summary": "S", "points": ["a"], "collection": "Tech"}\n```',
        'Sure! Here is the JSON:\n{"summary": "S", "points": ["a"], "collection": "Tech"}',
        '```\r\n{"summary": "S", "points": ["a"], "collection": "Tech"}\r\n```',
        '   {"summary": "S", "points": ["a"], "collection": "Tech"}   ',
      ]) {
        final i = fresh();
        Summarizer.apply(i, raw);
        expect(i.summary, 'S', reason: raw);
        expect(i.points, ['a'], reason: raw);
        expect(i.collection, 'tech', reason: raw);
      }
    });

    // BUG: parseJson slices from the first `{` to the LAST `}` of the whole reply, so any prose after the
    // JSON that contains a brace makes jsonDecode fail and the raw JSON text becomes the "summary".
    test('JSON followed by prose that contains braces', () {
      final i = fresh();
      Summarizer.apply(i, '{"summary": "S", "collection": "tech"}\n\nNote: placeholders look like {name}.');
      expect(i.summary, 'S');
    });

    test('two JSON objects: no raw JSON leaks into the summary', () {
      final i = fresh();
      Summarizer.apply(i, '{"summary": "S1"}\n{"summary": "S2"}');
      expect(i.summary, isNot(startsWith('{')));
    });

    // BUG: Gemma is capped at maxTokens=1000; when the JSON is cut off mid-string the fallback shows the
    // raw `{"title": ...` text as the summary (and "key points" are lost).
    test('truncated JSON does not put raw JSON into the summary', () {
      final i = fresh();
      Summarizer.apply(i, '{"title": "T", "summary": "A detailed summary that was cut');
      expect(i.summary, isNot(startsWith('{')));
      expect(i.summary, contains('A detailed summary'));
    });

    test('invalid JSON-ish prose with bullets and numbering', () {
      final i = fresh();
      Summarizer.apply(i, 'It is a pasta recipe.\n1. Boil\n2) Toss\n• Serve\n* Eat');
      expect(i.summary, 'It is a pasta recipe.');
      expect(i.points, ['Boil', 'Toss', 'Serve', 'Eat']);
    });

    // BUG: an empty (or whitespace / `{}`) reply is accepted: the item becomes "done" with no summary and
    // nothing explains why. It should be failed (and offer "summarise").
    test('an empty reply is not a successful summary', () async {
      for (final reply in ['', '   \n ', '{}', '{"summary": ""}', '```json\n```']) {
        final rig = await Rig.make(ask: _ok(reply), handler: (r) => html('T'));
        final item = await rig.share('https://example.com/a');
        expect(item.summary, isNull, reason: reply);
        expect(item.status, isNot(SavedStatus.done), reason: 'empty reply "$reply"');
      }
    });

    test('non-string and odd fields', () {
      var i = fresh();
      Summarizer.apply(
        i,
        '{"title": 5, "summary": ["a", "b"], "points": "one point", "tags": "x,y", "collection": 123}',
      );
      expect(i.title, '5');
      expect(i.summary, '[a, b]'); // lists are stringified; documented fallback, not a crash
      expect(i.points, ['one point']);
      expect(i.tags, ['x,y']);
      expect(i.collection, '123');

      i = fresh();
      Summarizer.apply(
        i,
        '{"summary": {"a": 1}, "points": [1, null, {"k": "v"}, "  ", "ok"], "tags": null, "collection": null}',
      );
      // BUG: a JSON null inside "points" becomes the literal key point "null".
      expect(i.points.where((p) => p == 'null'), isEmpty);
      expect(i.tags, isEmpty);
      expect(i.collection, 'other');
    });

    test('collection names are normalised; tags lowercased; limits applied', () {
      final i = fresh();
      Summarizer.apply(
        i,
        jsonEncode({
          'summary': 's',
          'collection': 'Healthy Recipes & More!!! With A Very Long Name',
          'tags': ['#A', 'B', 'c', 'd', 'e', 'f', 'g'],
          'points': [for (var n = 0; n < 12; n++) 'p$n'],
        }),
      );
      expect(i.collection!.length, lessThanOrEqualTo(20));
      expect(i.collection, 'healthy recipes & mo');
      expect(i.tags, ['a', 'b', 'c', 'd', 'e']);
      expect(i.points, hasLength(8));
    });

    test('model title only replaces the title when nothing better was read', () {
      var i = SavedItem(
        id: '1',
        created: DateTime(2026),
        url: 'https://e.com',
        title: 'Real title',
        sources: ['page preview'],
      );
      Summarizer.apply(i, '{"title": "Model title", "summary": "s"}');
      expect(i.title, 'Real title');
      i = SavedItem(
        id: '1',
        created: DateTime(2026),
        files: [
          {'path': '/a', 'name': 'a.png', 'kind': 'image'},
        ],
      );
      Summarizer.apply(i, '{"title": "Boarding pass", "summary": "s"}');
      expect(i.title, 'Boarding pass');
    });

    test('re-summarising replaces, not appends', () async {
      var n = 0;
      final rig = await Rig.make(
        handler: (r) => html('T'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          n++;
          return '{"summary": "run $n", "points": ["p$n"], "tags": ["t$n"], "collection": "tech"}';
        },
      );
      final item = await rig.share('https://example.com/a');
      await rig.sum.resummarise(item);
      expect(item.summary, 'run 2');
      expect(item.points, ['p2']);
      expect(item.tags, ['t2']);
      expect(item.sources.toSet().length, item.sources.length, reason: 'sources duplicated: ${item.sources}');
    });
  });

  group('pipeline states', () {
    test('NoModelError -> needsModel with the message; later success clears the error', () async {
      var model = false;
      final rig = await Rig.make(
        handler: (r) => html('Page', desc: 'about stuff'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          if (!model) throw const NoModelError('Download Gemma first.');
          return '{"summary": "ok"}';
        },
      );
      final item = await rig.share('https://example.com/a');
      expect((item.status, item.error), (SavedStatus.needsModel, 'Download Gemma first.'));
      expect(item.title, 'Page'); // the read part is kept
      model = true;
      await rig.sum.resummarise(item);
      expect((item.status, item.error, item.summary), (SavedStatus.done, null, 'ok'));
    });

    test('other model errors -> failed with the message; retry works', () async {
      var fail = true;
      final rig = await Rig.make(
        handler: (r) => html('Page'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          if (fail) throw StateError('out of memory');
          return '{"summary": "ok"}';
        },
      );
      final item = await rig.share('https://example.com/a');
      expect(item.status, SavedStatus.failed);
      expect(item.error, contains('out of memory'));
      fail = false;
      await rig.sum.resummarise(item);
      expect(item.status, SavedStatus.done);
    });

    test('statuses go reading -> summarising -> done, what was read is visible early, restart-safe', () async {
      final seen = <SavedStatus>[];
      final gate = Completer<void>();
      final rig = await Rig.make(
        handler: (r) => html('Page'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          await gate.future;
          return '{"summary": "ok"}';
        },
      );
      rig.saved.addListener(() {
        for (final i in rig.saved.items) {
          if (seen.isEmpty || seen.last != i.status) seen.add(i.status);
        }
      });
      final item = await rig.sum.addShare(text: 'https://example.com/a');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(item.status, SavedStatus.summarising);
      expect(item.title, 'Page', reason: 'what was read is visible before the summary');
      // a restart at this moment must not leave a spinner behind
      final mid = SavedStore(rig.store);
      await mid.load();
      expect(mid.items.single.status, SavedStatus.needsModel);
      gate.complete();
      await rig.settle();
      expect(seen, [SavedStatus.reading, SavedStatus.summarising, SavedStatus.done]);
    });

    test('the prompt is bounded even for a huge page, and carries share title, caption and creator', () async {
      final rig = await Rig.make(
        handler: (r) => r.url.path == '/oembed'
            ? jsonOk({'title': 'T', 'author_name': 'Creator'})
            : http.Response('"shortDescription":"${'long ' * 100000}"', 200),
      );
      await rig.share('Caption words https://www.youtube.com/watch?v=abc', subject: 'Shared title');
      final prompt = rig.asks.single;
      expect(prompt.length, lessThan(9000));
      expect(prompt, contains('Creator: Creator'));
      expect(prompt, contains('Text shared with it: Caption words'));
      expect(prompt, contains('Shared with the title: Shared title'));
    });

    test('rich page title wins over the share subject; a walled page keeps the subject', () async {
      var rig = await Rig.make(handler: (r) => html('Page title'));
      var item = await rig.share('https://example.com/a', subject: 'Subject');
      expect(item.title, 'Page title');
      rig = await Rig.make(handler: (r) => html('Login • Instagram'));
      item = await rig.share('https://www.instagram.com/reel/X/', subject: 'Pasta reel');
      expect(item.title, 'Pasta reel');
      expect(item.sources, contains('share title'));
    });

    // BUG: process() resets `sources` but not `body`; for screenshots/clips `body` is rebuilt with
    // `[?item.body, newText]`, so every "summarise again" appends the OCR text / transcript once more.
    test('re-summarising a screenshot does not duplicate the OCR text', () async {
      final rig = await Rig.make(
        canSee: true,
        ask: ({required system, required prompt, imagePaths = const []}) async =>
            system == Summarizer.ocrPrompt ? 'Gate 22' : '{"summary": "s"}',
      );
      final item = await rig.share(
        '',
        files: [
          {'path': '/t/s.png', 'name': 's.png', 'kind': 'image'},
        ],
      );
      expect(item.body, 'Gate 22');
      await rig.sum.resummarise(item);
      await rig.sum.resummarise(item);
      expect(item.body, 'Gate 22');
    });

    // BUG: same as above for a clip's transcript.
    test('re-summarising a clip does not duplicate the transcript', () async {
      final rig = await Rig.make(transcribe: (p) async => 'hello there', videoSheet: (p) async => '/t/sheet.jpg');
      final item = await rig.share(
        '',
        files: [
          {'path': '/t/v.mp4', 'name': 'v.mp4', 'kind': 'audio'},
        ],
      );
      await rig.sum.resummarise(item);
      expect('hello there'.allMatches(item.body!).length, 1);
    });

    test(
      'screenshots: at most 4 transcribed; NoModelError stops OCR; one failing OCR does not stop the rest',
      () async {
        var ocr = 0;
        final rig = await Rig.make(
          canSee: true,
          ask: ({required system, required prompt, imagePaths = const []}) async {
            if (system == Summarizer.ocrPrompt) {
              ocr++;
              if (ocr == 2) throw StateError('decode failed');
              return 'text $ocr';
            }
            return '{"summary": "s"}';
          },
        );
        final item = await rig.share(
          '',
          files: [
            for (var n = 0; n < 6; n++) {'path': '/t/$n.png', 'name': '$n.png', 'kind': 'image'},
          ],
        );
        expect(ocr, 4);
        expect(item.body, 'text 1\n\ntext 3\n\ntext 4');
        expect(item.status, SavedStatus.done);

        final noModel = await Rig.make(
          canSee: true,
          ask: ({required system, required prompt, imagePaths = const []}) async =>
              throw const NoModelError('no model'),
        );
        final i2 = await noModel.share(
          '',
          files: [
            {'path': '/t/1.png', 'name': '1.png', 'kind': 'image'},
            {'path': '/t/2.png', 'name': '2.png', 'kind': 'image'},
          ],
        );
        expect(noModel.asks, hasLength(2)); // 1 OCR (then break) + 1 summary
        expect(i2.status, SavedStatus.needsModel);
      },
    );

    test('OCR answering "no text" adds nothing', () async {
      final rig = await Rig.make(
        canSee: true,
        ask: ({required system, required prompt, imagePaths = const []}) async =>
            system == Summarizer.ocrPrompt ? 'No text found' : '{"summary": "a photo"}',
      );
      final item = await rig.share(
        '',
        files: [
          {'path': '/t/1.png', 'name': '1.png', 'kind': 'image'},
        ],
      );
      expect(item.body, isNull);
      expect(item.sources, contains('screenshot'));
    });

    // BUG: transcribe/videoSheet are called without a guard in Summarizer.process (AppServices wraps them,
    // but the callbacks' contract does not say so): a throwing callback leaves the item spinning forever.
    test('a throwing transcriber or video-sheet maker leaves the item failed, not spinning', () async {
      final rig = await Rig.make(
        transcribe: (p) async => throw StateError('whisper crashed'),
        videoSheet: (p) async => throw StateError('ffmpeg crashed'),
      );
      final item = await rig.share(
        '',
        files: [
          {'path': '/t/v.mp4', 'name': 'v.mp4', 'kind': 'audio'},
        ],
      );
      expect(item.busy, isFalse, reason: 'stuck in ${item.status}');
    });

    // BUG: _titleFromUrl runs Uri.decodeComponent on an already-decoded path segment, so a URL such as
    // /sale-100%25-off ("100%") throws FormatException from preview() (outside its try/catch) when the
    // site cannot be read; the item then spins forever.
    test('a URL path containing an encoded percent sign', () async {
      final rig = await Rig.make(handler: (r) => http.Response('', 404));
      final item = await rig.share('https://shop.example.com/sale-100%25-off');
      expect(item.busy, isFalse, reason: 'stuck in ${item.status}');
      expect(item.title, isNotNull);
    });

    test('cover images: https only, must be images, size-capped', () async {
      final dir = await Directory.systemTemp.createTemp('qa_saved_cover');
      addTearDown(() => dir.delete(recursive: true));
      Future<SavedItem> withCover(String og, http.Response cover) async {
        final rig = await Rig.make(
          filesDir: dir.path,
          canSee: true,
          handler: (r) => r.url.path.endsWith('.jpg') || r.url.path.endsWith('.png')
              ? cover
              : http.Response('<meta property="og:title" content="T"><meta property="og:image" content="$og">', 200),
        );
        return rig.share('https://blog.example.com/p');
      }

      final ok = await withCover(
        'https://cdn.example.com/c.jpg',
        http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/jpeg'}),
      );
      expect(ok.imagePath, endsWith('.jpg'));
      expect(File(ok.imagePath!).existsSync(), isTrue);
      expect(ok.sources, contains('cover image'));
      final plain = await withCover(
        'http://cdn.example.com/c.jpg',
        http.Response.bytes([1], 200, headers: {'content-type': 'image/jpeg'}),
      );
      expect(plain.imagePath, isNull);
      final notImage = await withCover(
        'https://cdn.example.com/c.jpg',
        http.Response('<html>', 200, headers: {'content-type': 'text/html'}),
      );
      expect(notImage.imagePath, isNull);
      final missing = await withCover(
        'https://cdn.example.com/c.jpg',
        http.Response('', 404, headers: {'content-type': 'image/jpeg'}),
      );
      expect(missing.imagePath, isNull);
      final big = http.Response.bytes(List.filled(6 * 1024 * 1024 + 1, 0), 200, headers: {'content-type': 'image/png'});
      expect((await withCover('https://cdn.example.com/c.png', big)).imagePath, isNull);
    });

    // BUG(low): og:image="/img/cover.png" (relative) is common in the wild; Uri.parse(...).scheme is '' so it
    // is dropped instead of resolved against the page URL.
    test('a relative og:image is resolved against the page', () async {
      final dir = await Directory.systemTemp.createTemp('qa_saved_cover2');
      addTearDown(() => dir.delete(recursive: true));
      final rig = await Rig.make(
        filesDir: dir.path,
        handler: (r) => r.url.path == '/img/cover.png'
            ? http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/png'})
            : http.Response(
                '<meta property="og:title" content="T"><meta property="og:image" content="/img/cover.png">',
                200,
              ),
      );
      final item = await rig.share('https://blog.example.com/p');
      expect(item.imagePath, isNotNull);
    });
  });

  // ───────────────────────── queue ─────────────────────────
  group('queue', () {
    test('several shares at once are summarised one at a time, in the order shared', () async {
      var running = 0, maxRunning = 0;
      final order = <String>[];
      final rig = await Rig.make(
        handler: (r) => html('T ${r.url.path}'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          running++;
          maxRunning = running > maxRunning ? running : maxRunning;
          order.add(RegExp(r'Link: \S+').firstMatch(prompt)!.group(0)!);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return '{"summary": "ok"}';
        },
      );
      for (var n = 1; n <= 5; n++) {
        await rig.sum.addShare(text: 'https://example.com/$n');
      }
      expect(rig.saved.items.map((i) => i.url), [
        for (var n = 5; n >= 1; n--) 'https://example.com/$n',
      ], reason: 'newest first');
      await rig.settle();
      expect(maxRunning, 1);
      expect(order, [for (var n = 1; n <= 5; n++) 'Link: https://example.com/$n']);
      expect(rig.saved.items.every((i) => i.status == SavedStatus.done), isTrue);
    });

    test('one failing item does not block those behind it', () async {
      final rig = await Rig.make(
        handler: (r) => html('T'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          if (prompt.contains('/2')) throw StateError('boom');
          return '{"summary": "ok"}';
        },
      );
      for (var n = 1; n <= 3; n++) {
        await rig.sum.addShare(text: 'https://example.com/$n');
      }
      await rig.settle();
      expect(rig.saved.items.map((i) => i.status), [SavedStatus.done, SavedStatus.failed, SavedStatus.done]);
    });

    test('re-summarise while busy runs after the current run, never concurrently', () async {
      var running = 0, maxRunning = 0, calls = 0;
      final first = Completer<void>();
      final rig = await Rig.make(
        handler: (r) => html('T'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          running++;
          maxRunning = running > maxRunning ? running : maxRunning;
          if (++calls == 1) await first.future;
          running--;
          return '{"summary": "run $calls"}';
        },
      );
      final item = await rig.sum.addShare(text: 'https://example.com/a');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(item.busy, isTrue);
      final again = rig.sum.resummarise(item);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      first.complete();
      await again;
      await rig.settle();
      expect(maxRunning, 1);
      expect(item.status, SavedStatus.done);
      expect(item.summary, 'run 2');
    });

    test('deleting an item while it is being summarised: no crash, no resurrection', () async {
      final gate = Completer<void>();
      final rig = await Rig.make(
        handler: (r) => html('T'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          await gate.future;
          return '{"summary": "ok"}';
        },
      );
      final item = await rig.sum.addShare(text: 'https://example.com/a');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(item.status, SavedStatus.summarising);
      await rig.saved.remove(item);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.saved.items, isEmpty);
      final reload = SavedStore(rig.store);
      await reload.load();
      expect(reload.items, isEmpty, reason: 'the late save must not bring the item back');
    });

    test('deleting an item that is queued behind another does not stop the queue', () async {
      final gate = Completer<void>();
      final rig = await Rig.make(
        handler: (r) => html('T'),
        ask: ({required system, required prompt, imagePaths = const []}) async {
          if (prompt.contains('/1')) await gate.future;
          return '{"summary": "ok"}';
        },
      );
      final a = await rig.sum.addShare(text: 'https://example.com/1');
      final b = await rig.sum.addShare(text: 'https://example.com/2');
      final c = await rig.sum.addShare(text: 'https://example.com/3');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await rig.saved.remove(b);
      gate.complete();
      await rig.settle();
      expect((a.status, c.status), (SavedStatus.done, SavedStatus.done));
      expect(rig.saved.items, [c, a]);
    });
  });

  // ───────────────────────── SavedStore ─────────────────────────
  group('SavedStore', () {
    test('persistence round-trip keeps every field, unicode and files', () async {
      final store = MemoryJsonStore();
      final s = SavedStore(store);
      final created = DateTime(2026, 5, 1, 12, 30, 15);
      final item = SavedItem(
        id: 'x1',
        created: created,
        sharedText: 'caption 😀 日本語',
        subject: 'Subject',
        url: 'https://example.com/a?b=c',
        platform: 'youtube',
        kind: 'video',
        title: 'Title “quoted” \n newline',
        author: 'Au',
        description: 'd',
        imageUrl: 'https://i/x.jpg',
        imagePath: '/t/x.jpg',
        files: [
          {'path': '/t/a.mp4', 'name': 'a.mp4', 'kind': 'audio'},
        ],
        body: 'b' * 50000,
        summary: 'S',
        points: ['p1', 'p2'],
        tags: ['t1'],
        collection: 'tech',
        status: SavedStatus.failed,
        error: 'oops',
        sources: ['caption', 'transcript'],
      );
      await s.add(item);
      final back = SavedStore(store);
      await back.load();
      expect(back.items.single.toJson(), item.toJson());
      expect(back.items.single.created, created);
      expect(back.items.single.status, SavedStatus.failed);
    });

    test('work interrupted by a restart resumes as "needs a summary"', () async {
      final store = MemoryJsonStore();
      final s = SavedStore(store);
      await s.add(SavedItem(id: '1', created: DateTime(2026), status: SavedStatus.reading));
      await s.add(SavedItem(id: '2', created: DateTime(2026), status: SavedStatus.summarising));
      final back = SavedStore(store);
      await back.load();
      expect(back.items.map((i) => i.status), [SavedStatus.needsModel, SavedStatus.needsModel]);
    });

    test('a full AppServices restart brings back items and ledger', () async {
      final store = MemoryJsonStore();
      var s = await AppServices.create(
        store: store,
        platform: 'demo',
        linkClient: Net((r) => html('Page', desc: 'about pasta')).client,
      );
      await s.receiveShare(text: 'https://example.com/pasta');
      for (var n = 0; n < 100 && s.saved.items.first.busy; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(s.saved.items.first.status, SavedStatus.done);
      final before = s.saved.items.first.toJson();
      s = await AppServices.create(store: store, platform: 'demo', linkClient: Net((r) => html('x')).client);
      expect(s.saved.items.single.toJson(), before);
      expect(s.ledger.entries.where((e) => e.network), isNotEmpty);
    });

    // BUG: fromJson casts `j['id'] as String` etc. without a guard, so one malformed record makes load()
    // throw; AppServices.create awaits it in Future.wait, so the app cannot start at all.
    test('one corrupt record does not lose everything or crash startup', () async {
      final store = MemoryJsonStore();
      await store.write('saved', [
        {'id': 'ok', 'created': '2026-01-01T00:00:00.000', 'title': 'fine', 'status': 'done'},
        {'title': 'no id'},
        {'id': 'bad-points', 'points': 'not a list'},
      ]);
      final s = SavedStore(store);
      await expectLater(s.load(), completes);
      expect(s.items.map((i) => i.id), contains('ok'));
    });

    test('unknown status / bad date fall back instead of throwing', () async {
      final store = MemoryJsonStore();
      await store.write('saved', [
        {'id': 'a', 'created': 'not a date', 'status': 'from-the-future'},
      ]);
      final s = SavedStore(store);
      await s.load();
      expect(s.items.single.status, SavedStatus.done);
    });

    group('search / collections', () {
      late SavedStore s;
      setUp(() async {
        s = SavedStore(MemoryJsonStore());
        await s.add(
          item0(
            id: '1',
            title: 'Pasta in 10 min',
            summary: 'Butter and parmesan',
            collection: 'recipes',
            tags: ['pasta', 'quick'],
            platform: 'instagram',
            url: 'https://www.instagram.com/reel/AbC/',
            author: 'chef.ana',
          ),
        );
        await s.add(
          item0(
            id: '2',
            title: 'C++ templates',
            body: 'A long body about SFINAE (really)',
            collection: 'tech',
            points: ['Use concepts'],
          ),
        );
        await s.add(
          item0(
            id: '3',
            title: 'Trip to İstanbul',
            description: 'Bosphorus ferries',
            collection: 'travel',
            platform: 'youtube',
          ),
        );
        await s.add(item0(id: '4', title: 'Untitled', collection: null, sharedText: 'my note 😀'));
        await s.add(item0(id: '5', title: 'Sourdough', collection: 'recipes', tags: ['bread']));
      });
      List<String> ids(String q, {String? c}) => s.search(q, collection: c).map((i) => i.id).toList();

      test('matching is case-insensitive over title, summary, body, tags, points, author, url, caption', () {
        expect(ids('PARMESAN'), ['1']);
        expect(ids('sfinae'), ['2']);
        expect(ids('concepts'), ['2']);
        expect(ids('quick'), ['1']);
        expect(ids('chef.ana'), ['1']);
        expect(ids('reel/abc'), ['1']);
        expect(ids('bosphorus'), ['3']);
        expect(ids('😀'), ['4']);
      });

      test('several words are ANDed, in any order; punctuation and regex characters are literal', () {
        expect(ids('butter pasta'), ['1']);
        expect(ids('butter sourdough'), isEmpty);
        expect(ids('c++'), ['2']);
        expect(ids('(really)'), ['2']);
        expect(ids('.*'), isEmpty);
        expect(ids('['), isEmpty);
      });

      test('empty / whitespace query returns everything, newest first; collection filter composes', () {
        expect(ids(''), ['5', '4', '3', '2', '1']);
        expect(ids('   '), ['5', '4', '3', '2', '1']);
        expect(ids('', c: 'recipes'), ['5', '1']);
        expect(ids('pasta', c: 'recipes'), ['1']);
        expect(ids('pasta', c: 'tech'), isEmpty);
        expect(ids('', c: 'nope'), isEmpty);
      });

      test('collections are listed by popularity and ignore items without one', () {
        expect(s.collections.first, 'recipes');
        expect(s.collections.toSet(), {'recipes', 'tech', 'travel'});
      });

      // BUG(low): the haystack omits collection name, platform, subject and file names, so typing "recipes",
      // "youtube" or "instagram" (the labels the app itself shows) finds nothing unless the word occurs in the text.
      test('searching by the collection or platform label shown in the UI', () {
        expect(ids('recipes'), containsAll(['1', '5']));
        expect(ids('youtube'), ['3']);
        expect(ids('instagram'), ['1']);
      });

      // BUG(low): no diacritic folding: "istanbul" does not find "İstanbul" (toLowerCase gives i + U+0307)
      // and "cafe" does not find "café".
      test('accents and dotted capitals are folded when searching', () async {
        await s.add(item0(id: '6', title: 'Café menu'));
        expect(ids('istanbul'), ['3']);
        expect(ids('cafe'), ['6']);
      });

      test('removing an item removes it from results and persists', () async {
        final item = s.byId('1')!;
        await s.remove(item);
        expect(ids('pasta'), isEmpty);
        expect(s.byId('1'), isNull);
        await s.clear();
        expect(s.items, isEmpty);
      });
    });
  });

  // ───────────────────────── widgets ─────────────────────────
  group('Saved screen', () {
    // A phone with a given logical size; 1 device pixel per logical pixel keeps it simple.
    void phone(WidgetTester t, {double w = 412, double h = 915}) {
      t.view.physicalSize = Size(w, h);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
    }

    // The default test font (Ahem) is far wider than the app's real faces, which would report overflows
    // that cannot happen on a phone. Load the bundled fonts.
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const families = {
        'Caveat': ['caveat_regular', 'caveat_semibold', 'caveat_bold'],
        'Inter': ['inter_regular', 'inter_medium', 'inter_semibold'],
        'Nunito': ['nunito_regular', 'nunito_semibold'],
        'ShantellSans': ['shantell_variable'],
        'PatrickHand': ['patrickhand_regular'],
      };
      for (final e in families.entries) {
        final loader = FontLoader(e.key);
        for (final f in e.value) {
          loader.addFont(rootBundle.load('assets/fonts/$f.ttf'));
        }
        await loader.load();
      }
    });

    final clipboard = <String?>[];
    String? clipboardIn;
    setUp(() {
      clipboard.clear();
      clipboardIn = null;
    });

    void mockClipboard(WidgetTester t) {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String?);
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return clipboardIn == null ? null : <String, dynamic>{'text': clipboardIn};
        }
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    Future<(AppServices, AppState)> boot(
      WidgetTester t, {
      List<SavedItem> items = const [],
      Handler? handler,
      bool dark = false,
    }) async {
      mockClipboard(t);
      final store = MemoryJsonStore();
      final services = (await t.runAsync(() async {
        final s = await AppServices.create(
          store: store,
          platform: 'demo',
          linkClient: Net(handler ?? (r) => html('Shared page', desc: 'About the page')).client,
        );
        await s.settings.update((x) => x.onboarded = true);
        for (final i in items.reversed) {
          await s.saved.add(i);
        }
        return s;
      }))!;
      if (dark) {
        t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(t.platformDispatcher.clearAllTestValues);
      }
      final state = AppState(services);
      await t.pumpWidget(PhoneDotsApp(state: state));
      await t.pump(const Duration(milliseconds: 500));
      state.goTo(AppState.savedTab);
      await t.pump(const Duration(milliseconds: 600));
      return (services, state);
    }

    Future<void> settleUi(WidgetTester t, [int ms = 700]) async {
      await t.pump();
      await t.pump(Duration(milliseconds: ms));
    }

    /// Scrolls the (lazy) page until [f] is built and on screen.
    Future<void> reveal(WidgetTester t, Finder f) async {
      await t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
      await t.pump(const Duration(milliseconds: 100));
    }

    Future<void> openRow(WidgetTester t, String title) async {
      await reveal(t, find.text(title));
      await t.tap(find.text(title));
      await settleUi(t);
    }

    List<SavedItem> everyStatus() => [
      item0(
        id: 'd',
        title: 'Done pasta',
        summary: 'A tasty summary of pasta.',
        points: ['Boil', 'Toss'],
        tags: ['pasta'],
        collection: 'recipes',
        url: 'https://example.com/pasta',
        sources: ['caption', 'page preview'],
        body: 'Boil the pasta then toss it in butter.',
      ),
      item0(id: 'r', title: 'Reading now', status: SavedStatus.reading, url: 'https://example.com/r'),
      item0(
        id: 's',
        title: 'Summarising now',
        status: SavedStatus.summarising,
        url: 'https://example.com/s',
        description: 'a caption',
      ),
      item0(
        id: 'n',
        title: 'Needs a model',
        status: SavedStatus.needsModel,
        error: 'Download Gemma 4 E2B in models first.',
        url: 'https://example.com/n',
      ),
      item0(
        id: 'f',
        title: 'Failed one',
        status: SavedStatus.failed,
        error: 'out of memory',
        url: 'https://example.com/f',
      ),
    ];

    testWidgets('empty state', (t) async {
      phone(t);
      await boot(t);
      expect(find.text('nothing saved yet'), findsOneWidget);
      expect(find.text('search what you saved'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('list shows every status, with status line, collection and no overflow at 320x640', (t) async {
      phone(t, w: 320, h: 640);
      await boot(t, items: everyStatus());
      expect(find.text('Done pasta'), findsOneWidget);
      Future<void> see(Finder f) => t.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
      await see(find.textContaining('summarising on this phone'));
      await see(find.textContaining('waiting for a model'));
      await see(find.textContaining('could not summarise'));
      await t.scrollUntilVisible(find.text('everything'), -150, scrollable: find.byType(Scrollable).first);
      expect(find.text('everything'), findsOneWidget);
      expect(find.text('recipes'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('list at 412x915 and in dark mode', (t) async {
      phone(t);
      await boot(t, items: everyStatus(), dark: true);
      expect(find.text('Done pasta'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('search narrows the list, "nothing matches" appears, clearing restores', (t) async {
      phone(t);
      await boot(t, items: everyStatus());
      await t.enterText(find.byType(TextField), 'pasta');
      await settleUi(t);
      expect(find.text('Done pasta'), findsOneWidget);
      expect(find.text('Failed one'), findsNothing);
      await t.enterText(find.byType(TextField), 'zzzzqq');
      await settleUi(t);
      expect(find.text('nothing matches'), findsOneWidget);
      await t.enterText(find.byType(TextField), '');
      await settleUi(t);
      expect(find.text('Failed one'), findsOneWidget);
    });

    testWidgets('collection pills filter; tapping the active pill clears it', (t) async {
      phone(t);
      await boot(
        t,
        items: [
          item0(id: '1', title: 'Pasta', collection: 'recipes'),
          item0(id: '2', title: 'Rust book', collection: 'tech'),
        ],
      );
      await t.tap(find.text('tech'));
      await settleUi(t);
      expect(find.text('Pasta'), findsNothing);
      expect(find.text('Rust book'), findsOneWidget);
      await t.tap(find.text('tech'));
      await settleUi(t);
      expect(find.text('Pasta'), findsOneWidget);
      await t.tap(find.text('recipes'));
      await settleUi(t);
      await t.tap(find.text('everything'));
      await settleUi(t);
      expect(find.text('Rust book'), findsOneWidget);
    });

    // BUG: when the filtered collection disappears (its last item is deleted/re-filed) and no collection is
    // left, the pills (including "everything") vanish while the filter stays set: the list says "nothing
    // matches" and the user cannot clear the filter, although other items exist.
    testWidgets('a vanished collection filter does not hide the remaining items', (t) async {
      phone(t);
      final (s, _) = await boot(
        t,
        items: [
          item0(id: '1', title: 'Pasta', collection: 'recipes'),
          item0(id: '2', title: 'No collection yet', collection: null),
        ],
      );
      await t.tap(find.text('recipes'));
      await settleUi(t);
      await t.runAsync(() => s.saved.remove(s.saved.byId('1')!));
      await settleUi(t);
      expect(find.text('No collection yet'), findsOneWidget);
    });

    testWidgets('tapping a row opens its detail; back returns to the list', (t) async {
      phone(t);
      await boot(t, items: everyStatus());
      await t.tap(find.text('Done pasta'));
      await settleUi(t);
      expect(find.byType(SavedDetailScreen), findsOneWidget);
      expect(find.text('summary'), findsOneWidget);
      await t.pageBack();
      await settleUi(t);
      expect(find.byType(SavedDetailScreen), findsNothing);
    });

    for (final (label, size, dark) in [
      ('320x640', const Size(320, 640), false),
      ('320x640', const Size(320, 640), true),
      ('412x915', const Size(412, 915), false),
      ('412x915', const Size(412, 915), true),
    ]) {
      testWidgets('detail of each status has no overflow at $label${dark ? ' (dark)' : ''}', (t) async {
        phone(t, w: size.width, h: size.height);
        final (s, _) = await boot(t, items: everyStatus(), dark: dark);
        for (final i in s.saved.items) {
          await openRow(t, i.title!);
          expect(find.byType(SavedDetailScreen), findsOneWidget, reason: i.title);
          expect(t.takeException(), isNull, reason: '${i.title} dark=$dark');
          await t.pageBack();
          await settleUi(t);
        }
      });
    }

    testWidgets('detail content per status', (t) async {
      phone(t);
      final (s, _) = await boot(t, items: everyStatus());
      Future<void> open(String title) async {
        await t.tap(find.text(title));
        await settleUi(t);
      }

      await open('Done pasta');
      // "what we read" comes before the summary
      final read = t.getTopLeft(find.text('what we read')).dy;
      final summary = t.getTopLeft(find.text('summary')).dy;
      expect(read, lessThan(summary));
      expect(find.text('Boil the pasta then toss it in butter.'), findsOneWidget);
      expect(find.text('A tasty summary of pasta.'), findsOneWidget);
      expect(find.text('key points'), findsOneWidget);
      expect(find.text('summarise again'), findsOneWidget);
      expect(find.textContaining('read from: caption, page preview'), findsOneWidget);
      await t.pageBack();
      await settleUi(t);

      await open('Reading now');
      expect(find.text('summarise again'), findsNothing);
      expect(find.text('summarise'), findsNothing);
      expect(find.textContaining('reading…'), findsOneWidget);
      await t.pageBack();
      await settleUi(t);

      await open('Summarising now');
      expect(find.textContaining('summarising on this phone…'), findsOneWidget);
      expect(find.text('caption'), findsOneWidget);
      await t.pageBack();
      await settleUi(t);

      await open('Needs a model');
      expect(find.text('Download Gemma 4 E2B in models first.'), findsOneWidget);
      expect(find.text('summarise'), findsOneWidget);
      await t.pageBack();
      await settleUi(t);

      await open('Failed one');
      expect(find.text('out of memory'), findsOneWidget);
      expect(find.text('summarise'), findsOneWidget);
      expect(s.saved.items, hasLength(5));
    });

    testWidgets('a link with nothing readable shows the screenshot hint, not an empty page', (t) async {
      phone(t);
      await boot(
        t,
        items: [
          item0(id: 'x', title: 'Instagram video', url: 'https://www.instagram.com/reel/X/', platform: 'instagram'),
        ],
      );
      await t.tap(find.text('Instagram video'));
      await settleUi(t);
      expect(find.textContaining('Share a screenshot or a screen recording'), findsOneWidget);
    });

    testWidgets('very long body folds to 2500 characters and unfolds', (t) async {
      phone(t);
      final body = '${List.generate(600, (n) => 'sentence$n').join(' ')} THE-VERY-END';
      expect(body.length, greaterThan(5000));
      await boot(
        t,
        items: [item0(id: 'l', title: 'Long read', summary: 's', body: body, url: 'https://example.com/l')],
      );
      await t.tap(find.text('Long read'));
      await settleUi(t);
      expect(find.textContaining('THE-VERY-END', findRichText: true), findsNothing);
      expect(find.textContaining('characters'), findsWidgets);
      final unfold = find.textContaining('read all');
      expect(unfold, findsOneWidget);
      await reveal(t, unfold);
      await t.tap(unfold);
      await settleUi(t);
      expect(find.textContaining('THE-VERY-END', findRichText: true), findsOneWidget);
      final fold = find.text('fold it up');
      await reveal(t, fold);
      await t.tap(fold);
      await settleUi(t);
      expect(find.textContaining('THE-VERY-END', findRichText: true), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('a 200 kB unbroken string and a 5000-character title do not overflow or throw', (t) async {
      phone(t, w: 320, h: 640);
      await boot(
        t,
        items: [
          item0(
            id: 'l',
            title: 'T' * 5000,
            summary: 'S' * 3000,
            body: 'x' * 200000,
            points: ['p' * 2000],
            url: 'https://example.com/${'a' * 3000}',
            author: 'A' * 500,
          ),
        ],
      );
      expect(t.takeException(), isNull);
      await t.tap(find.byType(Text).at(3));
      await settleUi(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('copy buttons put the text on the clipboard and say "copied"', (t) async {
      phone(t);
      await boot(t, items: everyStatus());
      await t.tap(find.text('Done pasta'));
      await settleUi(t);
      final copyText = find.text('copy the text');
      await reveal(t, copyText);
      await t.tap(copyText);
      await t.pump();
      expect(clipboard.last, 'Boil the pasta then toss it in butter.');
      expect(find.text('copied'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));

      final copySummary = find.text('copy the summary');
      await reveal(t, copySummary);
      await t.tap(copySummary);
      await t.pump();
      expect(clipboard.last, 'Done pasta\nA tasty summary of pasta.\n• Boil\n• Toss\nhttps://example.com/pasta');
    });

    testWidgets('delete asks first: "not now" keeps it, "delete" removes it and returns to the list', (t) async {
      phone(t);
      final (s, _) = await boot(t, items: everyStatus());
      await t.tap(find.text('Done pasta'));
      await settleUi(t);
      await t.tap(find.byTooltip('Delete'));
      await settleUi(t);
      expect(find.text('delete this?'), findsOneWidget);
      await t.tap(find.text('not now'));
      await settleUi(t);
      expect(s.saved.items, hasLength(5));
      expect(find.byType(SavedDetailScreen), findsOneWidget);

      await t.tap(find.byTooltip('Delete'));
      await settleUi(t);
      await t.tap(find.text('delete'));
      await settleUi(t);
      expect(s.saved.items.map((i) => i.id), isNot(contains('d')));
      expect(find.byType(SavedDetailScreen), findsNothing);
      expect(find.text('Done pasta'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('deleting the last item returns to the empty state', (t) async {
      phone(t);
      await boot(
        t,
        items: [item0(id: 'only', title: 'Only one', summary: 's')],
      );
      await t.tap(find.text('Only one'));
      await settleUi(t);
      await t.tap(find.byTooltip('Delete'));
      await settleUi(t);
      await t.tap(find.text('delete'));
      await settleUi(t);
      expect(find.text('nothing saved yet'), findsOneWidget);
    });

    testWidgets('an item deleted while its detail is open shows "gone"', (t) async {
      phone(t);
      final (s, _) = await boot(
        t,
        items: [
          item0(id: 'g', title: 'Going', summary: 's'),
          item0(id: 'h', title: 'Staying'),
        ],
      );
      await t.tap(find.text('Going'));
      await settleUi(t);
      await t.runAsync(() => s.saved.remove(s.saved.byId('g')!));
      await settleUi(t);
      expect(find.text('gone'), findsOneWidget);
    });

    testWidgets('"summarise again" re-runs the summary and shows the result', (t) async {
      phone(t);
      final (s, _) = await boot(
        t,
        items: [item0(id: 'a', title: 'Again', summary: 'old summary', url: 'https://example.com/a')],
      );
      await t.tap(find.text('Again'));
      await settleUi(t);
      final btn = find.text('summarise again');
      await reveal(t, btn);
      await t.tap(btn);
      await t.runAsync(() async {
        for (var n = 0; n < 100 && (s.saved.byId('a')!.busy || s.saved.byId('a')!.summary == 'old summary'); n++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await settleUi(t);
      expect(s.saved.byId('a')!.status, SavedStatus.done);
      expect(find.text('old summary'), findsNothing);
      expect(find.text('summary'), findsOneWidget);
    });

    testWidgets('"chat about it" goes to the chat tab and drops the detail', (t) async {
      phone(t);
      final (_, state) = await boot(
        t,
        items: [item0(id: 'a', title: 'Chat me', summary: 'sum', url: 'https://example.com/a')],
      );
      await t.tap(find.text('Chat me'));
      await settleUi(t);
      final btn = find.text('chat about it');
      await reveal(t, btn);
      await t.tap(btn);
      await settleUi(t, 1500);
      expect(state.tab, 0);
      expect(find.byType(SavedDetailScreen), findsNothing);
      expect(find.textContaining('Tell me more about this, which I saved'), findsWidgets);
    });

    testWidgets('a share while the app is open jumps to the Saved tab and opens its page', (t) async {
      phone(t);
      final (s, state) = await boot(
        t,
        items: [item0(id: 'a', title: 'Older', summary: 's')],
      );
      state.goTo(0);
      await settleUi(t);
      await t.runAsync(() => s.receiveShare(text: 'https://example.com/new-share'));
      await settleUi(t, 1000);
      expect(state.tab, AppState.savedTab);
      expect(find.byType(SavedDetailScreen), findsOneWidget);
      await t.runAsync(() async {
        for (var n = 0; n < 100 && s.saved.items.any((i) => i.busy); n++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await settleUi(t);
      expect(find.text('Shared page'), findsWidgets); // title read from the page
    });

    testWidgets('a second share while a detail page is open replaces it with the new one', (t) async {
      phone(t);
      final (s, _) = await boot(
        t,
        items: [item0(id: 'a', title: 'Older', summary: 's')],
      );
      await t.tap(find.text('Older'));
      await settleUi(t);
      await t.runAsync(() => s.receiveShare(text: 'https://example.com/another'));
      await settleUi(t, 1000);
      expect(find.byType(SavedDetailScreen), findsOneWidget);
      expect(find.text('Older'), findsNothing);
    });

    testWidgets('"save a link" sheet: a clipboard link is prefilled', (t) async {
      phone(t);
      await boot(t);
      clipboardIn = ' https://example.com/from-clipboard ';
      await t.tap(find.byTooltip('Save a link'));
      await settleUi(t);
      expect(find.text('save a link'), findsWidgets);
      expect(find.widgetWithText(TextField, 'https://example.com/from-clipboard'), findsOneWidget);
      expect(find.text('save & summarise'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('"save a link" sheet: non-link clipboard text is not prefilled', (t) async {
      phone(t);
      await boot(t);
      clipboardIn = 'buy milk';
      await t.tap(find.byTooltip('Save a link'));
      await settleUi(t);
      expect(find.widgetWithText(TextField, 'buy milk'), findsNothing);
      expect(find.byType(TextField).last, findsOneWidget);
      expect(t.takeException(), isNull);
    });

    Future<void> realDelay(WidgetTester t, [int ms = 300]) async {
      await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    }

    testWidgets('Saved tab is stable under many items (200) without exceptions', (t) async {
      phone(t, w: 320, h: 640);
      await boot(
        t,
        items: [
          for (var n = 0; n < 200; n++) item0(id: 'i$n', title: 'Item $n', summary: 'sum $n', collection: 'c${n % 7}'),
        ],
      );
      expect(find.text('Item 0'), findsOneWidget);
      await t.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await settleUi(t);
      expect(t.takeException(), isNull);
    });

    // Keep last: when it fails the Flutter tree is left inconsistent and later tests would inherit that.
    // BUG: `_addLink` calls `c.dispose()` right after `await showModalBottomSheet`, but the sheet's TextField
    // is still on screen for the exit animation: debug builds throw "A TextEditingController was used after
    // being disposed" (and the tree is left inconsistent). Dispose in the sheet's own State instead.
    testWidgets('closing the "save a link" sheet does not touch a disposed controller', (t) async {
      phone(t);
      await boot(t);
      clipboardIn = 'https://example.com/a';
      await t.tap(find.byTooltip('Save a link'));
      await settleUi(t);
      await t.tap(find.text('save & summarise'));
      await realDelay(t);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(t.takeException(), isNull);
    });
  });
}
