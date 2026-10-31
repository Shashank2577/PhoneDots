// QA: models, settings, onboarding, privacy, memory, my files, lab, voice.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:phonedots/agent/conversation.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/models/model_catalog.dart';
import 'package:phonedots/core/models/model_manager.dart';
import 'package:phonedots/core/models/model_spec.dart';
import 'package:phonedots/core/runtime/demo_engines.dart';
import 'package:phonedots/core/runtime/engine_types.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/core/util/downloader.dart';
import 'package:phonedots/features/models/models_screen.dart';
import 'package:phonedots/knowledge/knowledge_base.dart';
import 'package:phonedots/knowledge/memory_store.dart';
import 'package:phonedots/main.dart';
import 'package:phonedots/saved/saved_store.dart';
import 'package:phonedots/theme/theme.dart';
import 'package:phonedots/widgets/hand.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A store with a real models directory so the non-demo ModelManager paths run.
class _DirStore extends MemoryJsonStore {
  _DirStore(this.dir);
  final String dir;
  @override
  String? get modelsDir => dir;
}

class _FakeLlm extends DemoLlmEngine {
  final List<String> log = [];
  bool failLoad = false;
  @override
  bool get isDemo => false;
  @override
  Future<void> load({
    required String modelId,
    required String path,
    ComputeBackend backend = ComputeBackend.gpu,
    int maxTokens = 4096,
    bool vision = false,
    bool audio = false,
  }) async {
    if (failLoad) throw Exception('boom');
    log.add('load:$modelId:${backend.name}:$maxTokens:v$vision:a$audio');
    await super.load(modelId: modelId, path: path, backend: backend, maxTokens: maxTokens);
  }

  @override
  Future<void> unload(String modelId) async {
    log.add('unload:$modelId');
    await super.unload(modelId);
  }

  DeviceProfile profile = const DeviceProfile(platform: 'android', totalRamMb: 12000);
  @override
  Future<DeviceProfile> deviceProfile() async => profile;
}

class _FakeEmbedder extends LexicalEmbedder {
  bool ready = false;
  bool failLoad = false;
  @override
  bool get isReady => ready;
  @override
  Future<void> load({required String modelId, required String path}) async {
    if (failLoad) throw Exception('embed boom');
    ready = true;
  }
}

class _Rig {
  _Rig(this.dir, this.store, this.llm, this.embedder, this.settings, this.ledger, this.mgr);
  final Directory dir;
  final _DirStore store;
  final _FakeLlm llm;
  final _FakeEmbedder embedder;
  final AppSettings settings;
  final Ledger ledger;
  final ModelManager mgr;
}

Future<_Rig> _rig(http.Client client, {int ramMb = 12000}) async {
  final dir = Directory.systemTemp.createTempSync('pd_qa_models');
  final store = _DirStore(dir.path);
  final llm = _FakeLlm()..profile = DeviceProfile(platform: 'android', totalRamMb: ramMb);
  final emb = _FakeEmbedder();
  final settings = AppSettings(store);
  final ledger = Ledger(store);
  final mgr = ModelManager(
    store: store,
    llm: llm,
    embedder: emb,
    specialists: DemoSpecialistEngine(),
    settings: settings,
    ledger: ledger,
    client: client,
  );
  await mgr.init();
  return _Rig(dir, store, llm, emb, settings, ledger, mgr);
}

// ---------------------------------------------------------------------------
// Local HTTP server for the downloader (loopback only, no real network)
// ---------------------------------------------------------------------------

class _Req {
  _Req(this.range, this.auth);
  final String? range;
  final String? auth;
}

Future<(HttpServer, List<_Req>)> _serve(
  Future<void> Function(HttpRequest req, HttpResponse res) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <_Req>[];
  server.listen((req) async {
    seen.add(_Req(req.headers.value(HttpHeaders.rangeHeader), req.headers.value(HttpHeaders.authorizationHeader)));
    try {
      await handler(req, req.response);
    } catch (_) {}
  });
  return (server, seen);
}

/// Serves [body] honouring `Range: bytes=N-`.
Future<(HttpServer, List<_Req>)> _serveBody(Uint8List body, {bool honourRange = true}) => _serve((req, res) async {
  final r = req.headers.value(HttpHeaders.rangeHeader);
  if (r != null && honourRange) {
    final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(r)!.group(1)!);
    if (start >= body.length) {
      res.statusCode = 416;
      await res.close();
      return;
    }
    res.statusCode = 206;
    res.contentLength = body.length - start;
    res.add(body.sublist(start));
    await res.close();
    return;
  }
  res.statusCode = 200;
  res.contentLength = body.length;
  res.add(body);
  await res.close();
});

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + 3) & 0xff));
String _sha(List<int> b) => crypto.sha256.convert(b).toString();

// ---------------------------------------------------------------------------
// Widget harness
// ---------------------------------------------------------------------------

class _App {
  _App(this.state, this.services);
  final AppState state;
  final AppServices services;
}

Future<_App> _boot(
  WidgetTester tester, {
  Size size = const Size(412, 3000),
  bool onboarded = true,
  bool collect = false,
  ThemeMode theme = ThemeMode.light,
  MemoryJsonStore? store,
  Future<void> Function(AppServices s)? seed,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _errors.clear();
  if (collect) {
    _origOnError ??= FlutterError.onError;
    FlutterError.onError = _errors.add;
    addTearDown(_stopCollect);
  }
  final s = (await tester.runAsync(() async {
    final services = await AppServices.create(store: store ?? MemoryJsonStore(), platform: 'demo');
    await services.settings.update((x) {
      x.onboarded = onboarded;
      x.themeMode = theme;
    });
    if (seed != null) await seed(services);
    return services;
  }))!;
  final state = AppState(s);
  await tester.pumpWidget(PhoneDotsApp(state: state));
  await tester.pump(const Duration(seconds: 1));
  return _App(state, s);
}

Future<void> _settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _has(Finder f) {
  try {
    return f.evaluate().isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<void> _reveal(WidgetTester tester, Finder f) async {
  final sc = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical);
  for (final dy in [-250.0, 250.0]) {
    for (var i = 0; i < 30 && !_has(f) && _has(sc); i++) {
      await tester.drag(sc.last, Offset(0, dy), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  if (_has(f) && _has(sc)) {
    await tester.ensureVisible(f.first);
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, Finder f, [int ms = 500]) async {
  await _reveal(tester, f);
  expect(_has(f), isTrue, reason: 'tap target missing: ${f.describeMatch(Plurality.many)}');
  await tester.tap(f.first, warnIfMissed: false);
  await _settle(tester, ms);
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await _settle(tester);
}

Future<void> _door(WidgetTester tester, String label) async {
  await _tab(tester, 'you');
  await _tap(tester, find.widgetWithText(Door, label));
}

final List<FlutterErrorDetails> _errors = [];
void Function(FlutterErrorDetails)? _origOnError;

/// Restores the binding's own error handler (must happen before a test is allowed to fail).
void _stopCollect() {
  if (_origOnError != null) FlutterError.onError = _origOnError;
  _origOnError = null;
}

String _describeObj(Object e) {
  final text = e is FlutterError ? e.toStringDeep() : '$e';
  final px = RegExp(r'overflowed by ([\d.]+) pixels').firstMatch(text)?.group(1);
  final who = RegExp(r'error-causing widget was:\s*\n\s*(.+)').firstMatch(text)?.group(1)?.trim();
  return px != null ? 'overflow $px px in ${who ?? '?'}' : text.split('\n').first;
}

String _describeError(FlutterErrorDetails d) {
  final text = d.toString();
  final px = RegExp(r'overflowed by ([\d.]+) pixels').firstMatch(text)?.group(1);
  final who = RegExp(r'error-causing widget was:\s*\n\s*(.+)').firstMatch(text)?.group(1)?.trim();
  return px != null ? 'overflow $px px in ${who ?? '?'}' : d.exceptionAsString().split('\n').first;
}

void _noError(WidgetTester tester, String where) {
  final e = [for (final d in _errors) _describeError(d)];
  _errors.clear();
  final t = tester.takeException();
  if (t != null) e.add(_describeObj(t));
  expect(e, isEmpty, reason: 'error(s) while showing "$where": ${e.join('; ')}');
}

/// Records (instead of failing on) layout errors so one run lists every overflowing screen.
void _collect(WidgetTester tester, String where, List<String> out) {
  for (final d in _errors) {
    out.add('$where: ${_describeError(d)}');
  }
  _errors.clear();
  final t = tester.takeException();
  if (t != null) out.add('$where: ${_describeObj(t)}');
}

Future<void> _back(WidgetTester tester) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
  nav.pop();
  await _settle(tester);
}

Future<void> _seedRich(AppServices s) async {
  await s.memory.add('Prefers metric units and a very long fact that keeps going on and on so that it must wrap '
      'across several lines without overflowing anything in the row ' * 2);
  await s.memory.add('Lives in Zürich');
  await s.knowledge.add('A really quite long document title that needs wrapping onto lines', 'alpha beta gamma ' * 100,
      source: 'import');
  await s.knowledge.add('Notes', 'short note about bananas', source: 'notes');
  for (var i = 0; i < 6; i++) {
    await s.ledger.record('download', 'Started Gemma 4 E2B with a rather long ledger detail line number $i', network: i.isEven);
  }
  await s.conversations.save(Conversation(id: 'c1', title: 'Hello', messages: [ChatMessage(id: 'm1', isUser: true, text: 'hi')]));
  await s.saved.add(SavedItem(id: 's1', created: DateTime.now(), sharedText: 'https://example.com'));
}

// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  // flutter_test renders with Ahem (far wider than real faces) unless the bundled fonts are loaded.
  const files = {
    'Caveat': ['caveat_regular', 'caveat_semibold', 'caveat_bold'],
    'Inter': ['inter_regular', 'inter_medium', 'inter_semibold'],
    'Nunito': ['nunito_regular', 'nunito_semibold'],
    'ShantellSans': ['shantell_variable'],
    'PatrickHand': ['patrickhand_regular'],
  };
  for (final e in files.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      loader.addFont(rootBundle.load('assets/fonts/$f.ttf'));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  // ===================================================================
  group('catalog', () {
    test('ids are unique and lookup works', () {
      final ids = allModels.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final m in allModels) {
        expect(modelById(m.id), same(m));
      }
      expect(modelById('nope'), isNull);
    });

    test('every app-downloaded model has repo, file, sha256 and a plausible size', () {
      for (final m in gemmaModels) {
        expect(m.appDownloads, isTrue, reason: m.id);
        expect(m.hfRepo, isNotEmpty, reason: m.id);
        expect(m.fileName, endsWith('.litertlm'), reason: m.id);
        expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: m.id);
        expect(m.approxBytes, greaterThan(100 * 1000 * 1000), reason: m.id);
        expect(m.downloadUrl, 'https://huggingface.co/${m.hfRepo}/resolve/main/${m.fileName}?download=true');
        expect(m.hfPage, 'https://huggingface.co/${m.hfRepo}');
      }
      final files = gemmaModels.map((m) => '${m.hfRepo}/${m.fileName}').toList();
      expect(files.toSet().length, files.length, reason: 'two models share a file');
      final shas = gemmaModels.map((m) => m.sha256).toList();
      expect(shas.toSet().length, shas.length, reason: 'two models share a sha');
    });

    test('desert ant models are SDK-downloaded (no repo, file or sha)', () {
      for (final m in desertAntModels) {
        expect(m.appDownloads, isFalse, reason: m.id);
        expect(m.fileName, isNull);
        expect(m.sha256, isNull);
        expect(m.downloadUrl, isNull);
        expect(m.hfPage, isNull);
        expect(m.id, startsWith('desertant.'));
        expect(m.gated, isFalse);
        expect(m.role, ModelRole.specialist);
        expect(m.approxBytes, greaterThan(0));
      }
    });

    test('recommended models exist for planner, router and embedder', () {
      final rec = allModels.where((m) => m.recommended).toList();
      expect(rec.map((m) => m.role).toSet(), {ModelRole.planner, ModelRole.router, ModelRole.embedder});
      final s = AppSettings(MemoryJsonStore());
      expect(modelById(s.plannerId)?.role, ModelRole.planner);
      expect(modelById(s.routerId)?.role, ModelRole.router);
      expect(modelById(s.embedderId)?.role, ModelRole.embedder);
      expect(modelById(s.plannerId)!.recommended, isTrue);
      expect(modelById(s.routerId)!.recommended, isTrue);
      expect(modelById(s.embedderId)!.recommended, isTrue);
    });

    test('only FunctionGemma and Gemma 3 270M are gated', () {
      final gated = allModels.where((m) => m.gated).map((m) => m.id).toSet();
      expect(gated, {'functiongemma-270m-mobile-actions', 'gemma-3-270m'});
    });

    test('platform support and capability flags', () {
      for (final m in allModels) {
        expect(m.supports('demo'), isTrue);
      }
      final uhm = modelById('desertant.uhm')!;
      expect(uhm.supports('android'), isFalse);
      expect(uhm.supports('ios'), isTrue);
      expect(modelById('desertant.voz')!.supports('android'), isTrue);
      expect(modelById('gemma-4-e2b')!.has(ModelCapability.audio), isTrue);
      expect(modelById('gemma-3-270m')!.has(ModelCapability.tools), isFalse);
      // RAM thresholds: E4B needs more than E2B.
      expect(modelById('gemma-4-e4b')!.minRamMb, greaterThan(modelById('gemma-4-e2b')!.minRamMb));
    });
  });

  // ===================================================================
  group('classifyAccess', () {
    test('matrix', () {
      for (final s in [200, 206, 302, 303, 307]) {
        expect(classifyAccess(s, hasToken: false), Access.ok, reason: '$s');
        expect(classifyAccess(s, hasToken: true), Access.ok, reason: '$s');
      }
      expect(classifyAccess(401, hasToken: false), Access.needsToken);
      expect(classifyAccess(401, hasToken: true), Access.badToken);
      expect(classifyAccess(403, hasToken: false), Access.needsToken);
      expect(classifyAccess(403, hasToken: true), Access.needsLicence);
      for (final s in [0, 301, 304, 400, 404, 416, 429, 500, 503]) {
        expect(classifyAccess(s, hasToken: true), Access.unknown, reason: '$s');
        expect(classifyAccess(s, hasToken: false), Access.unknown, reason: '$s');
      }
    });
  });

  // ===================================================================
  group('ModelManager (non-demo)', () {
    test('checkAccess sends Range + bearer, does not follow redirects, logs to ledger', () async {
      http.BaseRequest? seen;
      final r = await _rig(http_testing.MockClient.streaming((req, body) async {
        seen = req;
        return http.StreamedResponse(const Stream.empty(), 302);
      }));
      final fg = modelById('functiongemma-270m-mobile-actions')!;
      r.settings.hfToken = 'hf_abc';
      expect(await r.mgr.checkAccess(fg), Access.ok);
      expect(seen!.headers['Range'], 'bytes=0-0');
      expect(seen!.headers['Authorization'], 'Bearer hf_abc');
      expect(seen!.followRedirects, isFalse);
      expect(seen!.url.toString(), fg.downloadUrl);
      await Future<void>.delayed(Duration.zero);
      expect(r.ledger.networkEvents, 1);
    });

    test('checkAccess maps statuses; no auth header without token', () async {
      for (final (status, hasToken, expected) in [
        (401, false, Access.needsToken),
        (401, true, Access.badToken),
        (403, false, Access.needsToken),
        (403, true, Access.needsLicence),
        (200, true, Access.ok),
        (206, false, Access.ok),
        (404, true, Access.unknown),
      ]) {
        String? auth;
        final r = await _rig(http_testing.MockClient.streaming((req, body) async {
          auth = req.headers['Authorization'];
          return http.StreamedResponse(const Stream.empty(), status);
        }));
        r.settings.hfToken = hasToken ? 'hf_x' : '';
        final a = await r.mgr.checkAccess(modelById('gemma-3-270m')!);
        expect(a, expected, reason: '$status token=$hasToken');
        expect(auth, hasToken ? 'Bearer hf_x' : isNull);
      }
    });

    test('checkAccess: network error -> unknown; non-gated -> ok without a request', () async {
      var calls = 0;
      final r = await _rig(http_testing.MockClient.streaming((req, body) async {
        calls++;
        throw const SocketException('offline');
      }));
      expect(await r.mgr.checkAccess(modelById('gemma-3-270m')!), Access.unknown);
      expect(calls, 1);
      expect(await r.mgr.checkAccess(modelById('gemma-4-e2b')!), Access.ok);
      expect(calls, 1);
    });

    test('canTryDownload: gated needs a token', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      final fg = modelById('functiongemma-270m-mobile-actions')!;
      expect(r.mgr.canTryDownload(fg), isFalse);
      expect(r.mgr.canTryDownload(modelById('gemma-4-e2b')!), isTrue);
      r.settings.hfToken = 'hf_1';
      expect(r.mgr.canTryDownload(fg), isTrue);
    });

    test('download of a gated model without token fails with guidance and no network', () async {
      var calls = 0;
      final r = await _rig(http_testing.MockClient.streaming((req, body) async {
        calls++;
        return http.StreamedResponse(const Stream.empty(), 200);
      }));
      await r.mgr.download('gemma-3-270m');
      expect(r.mgr.state('gemma-3-270m').status, ModelStatus.failed);
      expect(r.mgr.state('gemma-3-270m').error, contains('get access'));
      expect(calls, 0);
    });

    test('RAM fit warnings and visible models', () async {
      final low = await _rig(http_testing.MockClient((_) async => http.Response('', 200)), ramMb: 4000);
      expect(low.mgr.fits(modelById('gemma-4-e2b')!), isFalse);
      expect(low.mgr.fits(modelById('gemma-4-e4b')!), isFalse);
      expect(low.mgr.fits(modelById('gemma-3-270m')!), isTrue);
      final hi = await _rig(http_testing.MockClient((_) async => http.Response('', 200)), ramMb: 12000);
      expect(hi.mgr.fits(modelById('gemma-4-e4b')!), isTrue);
      // Unknown RAM (0) never blocks.
      final unk = await _rig(http_testing.MockClient((_) async => http.Response('', 200)), ramMb: 0);
      expect(unk.mgr.fits(modelById('gemma-4-e4b')!), isTrue);
      // android hides non-android specialists
      expect(hi.mgr.visibleModels.any((m) => m.id == 'desertant.uhm'), isFalse);
      expect(hi.mgr.visibleModels.any((m) => m.id == 'desertant.voz'), isTrue);
    });

    test('init detects files on disk; storageUsed uses real size; delete removes file and part', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      final m = modelById('gemma-4-e2b')!;
      expect(r.mgr.isReady(m.id), isFalse);
      expect(r.mgr.storageUsed, 0);
      File(r.mgr.pathFor(m)!).writeAsBytesSync(_bytes(1234));
      File('${r.mgr.pathFor(m)!}.part').writeAsBytesSync(_bytes(10));
      await r.mgr.init();
      expect(r.mgr.isReady(m.id), isTrue);
      expect(r.mgr.storageUsed, 1234);
      await r.mgr.delete(m.id);
      expect(r.mgr.isReady(m.id), isFalse);
      expect(File(r.mgr.pathFor(m)!).existsSync(), isFalse);
      expect(File('${r.mgr.pathFor(m)!}.part').existsSync(), isFalse);
      expect(r.mgr.storageUsed, 0);
    });

    test('ensurePlanner: unavailable -> false; loads with options; switching unloads previous', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      expect(await r.mgr.ensurePlanner(), isFalse);
      for (final id in ['gemma-4-e2b', 'gemma-4-e4b', 'functiongemma-270m-mobile-actions']) {
        File(r.mgr.pathFor(modelById(id)!)!).writeAsBytesSync(_bytes(8));
      }
      await r.mgr.init();
      expect(await r.mgr.ensurePlanner(), isTrue);
      expect(r.llm.log.last, 'load:gemma-4-e2b:gpu:4096:vtrue:atrue');
      expect(r.mgr.loadedPlanner, 'gemma-4-e2b');
      // idempotent
      final n = r.llm.log.length;
      expect(await r.mgr.ensurePlanner(), isTrue);
      expect(r.llm.log.length, n);
      // router uses small context and loads independently
      expect(await r.mgr.ensureRouter(), isTrue);
      expect(r.llm.log.last, 'load:functiongemma-270m-mobile-actions:gpu:1024:vfalse:afalse');
      expect(r.mgr.loadedPlanner, 'gemma-4-e2b');
      // switch planner
      await r.settings.update((x) {
        x.plannerId = 'gemma-4-e4b';
        x.useGpu = false;
      });
      expect(await r.mgr.ensurePlanner(), isTrue);
      expect(r.llm.log, contains('unload:gemma-4-e2b'));
      expect(r.llm.log.last, 'load:gemma-4-e4b:cpu:4096:vtrue:atrue');
    });

    test('low-memory phone unloads the router before loading E4B', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)), ramMb: 7000);
      for (final id in ['gemma-4-e4b', 'functiongemma-270m-mobile-actions']) {
        File(r.mgr.pathFor(modelById(id)!)!).writeAsBytesSync(_bytes(8));
      }
      await r.mgr.init();
      expect(await r.mgr.ensureRouter(), isTrue);
      await r.settings.update((x) => x.plannerId = 'gemma-4-e4b');
      expect(await r.mgr.ensurePlanner(), isTrue);
      expect(r.mgr.loadedRouter, isNull);
      expect(r.llm.log, contains('unload:functiongemma-270m-mobile-actions'));
    });

    test('load failure sets loadError, returns false and clears loadingModel', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      File(r.mgr.pathFor(modelById('gemma-4-e2b')!)!).writeAsBytesSync(_bytes(8));
      await r.mgr.init();
      r.llm.failLoad = true;
      expect(await r.mgr.ensurePlanner(), isFalse);
      expect(r.mgr.loadError, contains('Could not load Gemma 4 E2B'));
      expect(r.mgr.loadingModel, isNull);
      expect(r.mgr.loadedPlanner, isNull);
    });

    test('delete of a loaded model unloads it', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      File(r.mgr.pathFor(modelById('gemma-4-e2b')!)!).writeAsBytesSync(_bytes(8));
      await r.mgr.init();
      await r.mgr.ensurePlanner();
      await r.mgr.delete('gemma-4-e2b');
      expect(r.mgr.loadedPlanner, isNull);
      expect(r.llm.isLoaded('gemma-4-e2b'), isFalse);
    });

    test('ensureEmbedder: needs model on disk, loads once, reports failure', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      expect(await r.mgr.ensureEmbedder(), isFalse);
      File(r.mgr.pathFor(modelById('embeddinggemma-2-text-270m')!)!).writeAsBytesSync(_bytes(8));
      await r.mgr.init();
      r.embedder.failLoad = true;
      expect(await r.mgr.ensureEmbedder(), isFalse);
      expect(r.mgr.loadError, contains('embed boom'));
      r.embedder.failLoad = false;
      expect(await r.mgr.ensureEmbedder(), isTrue);
      expect(await r.mgr.ensureEmbedder(), isTrue);
    });

    test('settings pointing at an unknown model id do not crash ensure*', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      await r.settings.update((x) {
        x.plannerId = 'gone';
        x.routerId = 'gone';
        x.embedderId = 'gone';
      });
      expect(await r.mgr.ensurePlanner(), isFalse);
      expect(await r.mgr.ensureRouter(), isFalse);
      expect(await r.mgr.ensureEmbedder(), isFalse);
    });

    test('cancel on an id with no download is a no-op', () async {
      final r = await _rig(http_testing.MockClient((_) async => http.Response('', 200)));
      r.mgr.cancel('gemma-4-e2b');
    });
  });

  // ===================================================================
  group('downloadFile (loopback server)', () {
    late Directory tmp;
    setUp(() {
      // The widget-test binding replaces dart:io HttpClient with a stub that answers 400.
      HttpOverrides.global = null;
      tmp = Directory.systemTemp.createTempSync('pd_dl');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<List<DownloadProgress>> run(String url, String dest,
        {String? sha, Map<String, String> headers = const {}, CancelToken? token}) async {
      final out = <DownloadProgress>[];
      await for (final p in downloadFile(
        url: url,
        destPath: dest,
        sha256: sha,
        headers: headers,
        token: token ?? CancelToken(),
      )) {
        out.add(p);
      }
      return out;
    }

    test('full download, verified, progress ends at 1.0, headers forwarded', () async {
      final body = _bytes(300000);
      final (server, seen) = await _serveBody(body);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      final p = await run('http://127.0.0.1:${server.port}/f', dest, sha: _sha(body), headers: {'Authorization': 'Bearer t'});
      expect(File(dest).readAsBytesSync(), body);
      expect(File('$dest.part').existsSync(), isFalse);
      expect(p.last.fraction, 1.0);
      expect(seen.single.auth, 'Bearer t');
      expect(seen.single.range, isNull);
    });

    test('resumes from a .part file with a Range header', () async {
      final body = _bytes(100000);
      final (server, seen) = await _serveBody(body);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      File('$dest.part').writeAsBytesSync(body.sublist(0, 40000));
      final p = await run('http://127.0.0.1:${server.port}/f', dest, sha: _sha(body));
      expect(seen.single.range, 'bytes=40000-');
      expect(File(dest).readAsBytesSync(), body);
      expect(p.last.received, body.length);
      expect(p.last.total, body.length);
    });

    test('server ignoring Range (200) restarts from zero without corrupting', () async {
      final body = _bytes(50000);
      final (server, seen) = await _serveBody(body, honourRange: false);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      File('$dest.part').writeAsBytesSync(body.sublist(0, 20000));
      await run('http://127.0.0.1:${server.port}/f', dest, sha: _sha(body));
      expect(seen.single.range, 'bytes=20000-');
      expect(File(dest).readAsBytesSync(), body);
    });

    test('416 means the part file is already complete', () async {
      final body = _bytes(30000);
      final (server, _) = await _serveBody(body);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      File('$dest.part').writeAsBytesSync(body);
      await run('http://127.0.0.1:${server.port}/f', dest, sha: _sha(body));
      expect(File(dest).readAsBytesSync(), body);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('416 with an oversized/corrupt part: checksum catches it and the part is deleted', () async {
      final body = _bytes(30000);
      final (server, _) = await _serveBody(body);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      File('$dest.part').writeAsBytesSync(_bytes(35000));
      await expectLater(run('http://127.0.0.1:${server.port}/f', dest, sha: _sha(body)), throwsA(isA<ChecksumMismatch>()));
      expect(File('$dest.part').existsSync(), isFalse);
      expect(File(dest).existsSync(), isFalse);
    });

    test('wrong SHA-256 deletes the part and never produces the final file', () async {
      final body = _bytes(20000);
      final (server, _) = await _serveBody(body);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      await expectLater(
        run('http://127.0.0.1:${server.port}/f', dest, sha: 'a' * 64),
        throwsA(isA<ChecksumMismatch>().having((e) => e.toString(), 'msg', contains('Checksum mismatch'))),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('interrupted stream keeps the partial and a retry resumes to a verified file', () async {
      final body = _bytes(200000);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final ranges = <String?>[];
      var first = true;
      server.listen((sock) async {
        final req = StringBuffer();
        await for (final chunk in sock) {
          req.write(String.fromCharCodes(chunk));
          if (req.toString().contains('\r\n\r\n')) break;
        }
        final m = RegExp(r'range: bytes=(\d+)-', caseSensitive: false).firstMatch(req.toString());
        ranges.add(m?.group(0));
        if (first) {
          first = false;
          sock.add('HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\n\r\n'.codeUnits);
          sock.add(body.sublist(0, 60000));
          await sock.flush();
          sock.destroy();
        } else {
          final start = int.parse(m!.group(1)!);
          sock.add('HTTP/1.1 206 Partial Content\r\ncontent-length: ${body.length - start}\r\n\r\n'.codeUnits);
          sock.add(body.sublist(start));
          await sock.flush();
          await sock.close();
        }
      });
      final dest = '${tmp.path}/m.bin';
      final url = 'http://127.0.0.1:${server.port}/f';
      await expectLater(run(url, dest, sha: _sha(body)).timeout(const Duration(seconds: 10)), throwsA(isA<Exception>()));
      final partial = File('$dest.part').lengthSync();
      expect(partial, greaterThan(0));
      expect(partial, lessThan(body.length));
      expect(File(dest).existsSync(), isFalse);
      await run(url, dest, sha: _sha(body));
      expect(ranges.last?.toLowerCase(), 'range: bytes=$partial-');
      expect(File(dest).readAsBytesSync(), body);
    });

    test('HTTP 401 / 403 / 500 throw with the status in the message', () async {
      for (final code in [401, 403, 404, 500]) {
        final (server, _) = await _serve((req, res) async {
          res.statusCode = code;
          await res.close();
        });
        addTearDown(() => server.close(force: true));
        await expectLater(
          run('http://127.0.0.1:${server.port}/f', '${tmp.path}/$code.bin'),
          throwsA(predicate((e) => '$e'.contains('HTTP $code'))),
        );
        expect(File('${tmp.path}/$code.bin').existsSync(), isFalse);
      }
    });

    test('cancel stops mid-stream with DownloadCancelled and leaves the part for resume', () async {
      final body = _bytes(2000000);
      final (server, _) = await _serve((req, res) async {
        res.statusCode = 200;
        res.contentLength = body.length;
        for (var i = 0; i < body.length; i += 100000) {
          res.add(body.sublist(i, i + 100000));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await res.close();
      });
      addTearDown(() => server.close(force: true));
      final token = CancelToken();
      final dest = '${tmp.path}/m.bin';
      Timer(const Duration(milliseconds: 60), token.cancel);
      await expectLater(
        () async {
          await for (final _ in downloadFile(url: 'http://127.0.0.1:${server.port}/f', destPath: dest, token: token)) {}
        }(),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isTrue);
    });

    test('no sha given -> file is accepted as is', () async {
      final body = _bytes(1000);
      final (server, _) = await _serveBody(body);
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      await run('http://127.0.0.1:${server.port}/f', dest);
      expect(File(dest).readAsBytesSync(), body);
    });

    test('empty body and zero content-length', () async {
      final (server, _) = await _serveBody(Uint8List(0));
      addTearDown(() => server.close(force: true));
      final dest = '${tmp.path}/m.bin';
      final p = await run('http://127.0.0.1:${server.port}/f', dest, sha: _sha(<int>[]));
      expect(File(dest).lengthSync(), 0);
      expect(p.last.fraction, 0);
    });

    test('helpers: fileExists / fileSize / deleteFile', () async {
      final f = '${tmp.path}/x';
      expect(fileExists(f), isFalse);
      expect(fileSize(f), 0);
      File(f).writeAsBytesSync([1, 2, 3]);
      File('$f.part').writeAsBytesSync([1]);
      expect(fileExists(f), isTrue);
      expect(fileSize(f), 3);
      await deleteFile(f);
      expect(File(f).existsSync() || File('$f.part').existsSync(), isFalse);
      await deleteFile(f); // idempotent
    });

    test('DownloadProgress.fraction with unknown total', () {
      expect(const DownloadProgress(10, 0).fraction, 0);
      expect(const DownloadProgress(10, -1).fraction, 0);
      expect(const DownloadProgress(5, 10).fraction, 0.5);
    });
  });

  // ===================================================================
  group('AppSettings', () {
    test('defaults', () {
      final s = AppSettings(MemoryJsonStore());
      expect(s.themeMode, ThemeMode.system);
      expect(s.voice, 'neat');
      expect(s.hfToken, '');
      expect(s.thinking, isFalse);
      expect(s.useRouter, isTrue);
      expect(s.readLinks, isTrue);
      expect(s.autoSummarise, isTrue);
      expect(s.webReader, isFalse, reason: 'sends links to Jina: must be opt-in');
      expect(s.youtubeKey, '');
      expect(s.jinaKey, '');
      expect(s.useGpu, isTrue);
      expect(s.maxSteps, 6);
      expect(s.temperature, 0.7);
      expect(s.onboarded, isFalse);
      expect(s.disabledSkills, isEmpty);
      expect(s.grantedSkills, isEmpty);
    });

    test('every field round-trips through a fresh instance', () async {
      final store = MemoryJsonStore();
      final a = AppSettings(store);
      await a.update((x) {
        x.themeMode = ThemeMode.dark;
        x.voice = 'handwritten';
        x.hfToken = 'hf_tok';
        x.plannerId = 'gemma-4-e4b';
        x.routerId = 'other-router';
        x.embedderId = 'embeddinggemma-2-text-vision-440m';
        x.thinking = true;
        x.useRouter = false;
        x.readLinks = false;
        x.autoSummarise = false;
        x.webReader = true;
        x.youtubeKey = 'yt-key';
        x.jinaKey = 'jina-key';
        x.useGpu = false;
        x.maxSteps = 11;
        x.temperature = 1.2;
        x.onboarded = true;
        x.disabledSkills = {'a', 'b'};
        x.grantedSkills = {'c'};
      });
      final b = AppSettings(store);
      await b.load();
      expect(b.themeMode, ThemeMode.dark);
      expect(b.voice, 'handwritten');
      expect(b.hfToken, 'hf_tok');
      expect(b.plannerId, 'gemma-4-e4b');
      expect(b.routerId, 'other-router');
      expect(b.embedderId, 'embeddinggemma-2-text-vision-440m');
      expect(b.thinking, isTrue);
      expect(b.useRouter, isFalse);
      expect(b.readLinks, isFalse);
      expect(b.autoSummarise, isFalse);
      expect(b.webReader, isTrue);
      expect(b.youtubeKey, 'yt-key');
      expect(b.jinaKey, 'jina-key');
      expect(b.useGpu, isFalse);
      expect(b.maxSteps, 11);
      expect(b.temperature, 1.2);
      expect(b.onboarded, isTrue);
      expect(b.disabledSkills, {'a', 'b'});
      expect(b.grantedSkills, {'c'});
    });

    test('all three theme modes and all voices persist', () async {
      for (final m in ThemeMode.values) {
        final store = MemoryJsonStore();
        await AppSettings(store).update((x) => x.themeMode = m);
        final b = AppSettings(store);
        await b.load();
        expect(b.themeMode, m);
      }
      for (final v in Voice.values) {
        final store = MemoryJsonStore();
        await AppSettings(store).update((x) => x.voice = v.name);
        final b = AppSettings(store);
        await b.load();
        expect(b.voice, v.name);
      }
    });

    test('older JSON without the newer keys loads with defaults', () async {
      final store = MemoryJsonStore();
      await store.write('settings', {
        'themeMode': 'light',
        'voice': 'formal',
        'hfToken': 'hf_old',
        'plannerId': 'gemma-4-e2b',
        'thinking': true,
        'maxSteps': 4,
        'temperature': 1, // int, not double
      });
      final s = AppSettings(store);
      await s.load();
      expect(s.themeMode, ThemeMode.light);
      expect(s.hfToken, 'hf_old');
      expect(s.thinking, isTrue);
      expect(s.maxSteps, 4);
      expect(s.temperature, 1.0);
      expect(s.readLinks, isTrue);
      expect(s.autoSummarise, isTrue);
      expect(s.webReader, isFalse);
      expect(s.youtubeKey, '');
      expect(s.jinaKey, '');
      expect(s.useRouter, isTrue);
      expect(s.useGpu, isTrue);
      expect(s.routerId, 'functiongemma-270m-mobile-actions');
      expect(s.embedderId, 'embeddinggemma-2-text-270m');
      expect(s.disabledSkills, isEmpty);
    });

    test('an old install that predates "onboarded" shows the welcome once (documented default)', () async {
      final store = MemoryJsonStore();
      await store.write('settings', {'themeMode': 'dark'});
      final s = AppSettings(store);
      await s.load();
      expect(s.onboarded, isFalse);
    });

    test('empty JSON map and missing store load without throwing', () async {
      final store = MemoryJsonStore();
      final a = AppSettings(store);
      await a.load();
      await store.write('settings', <String, dynamic>{});
      final b = AppSettings(store);
      await b.load();
      expect(b.maxSteps, 6);
    });

    test('unknown themeMode name does not crash startup', () async {
      final store = MemoryJsonStore();
      await store.write('settings', {'themeMode': 'sepia', 'voice': 'x'});
      final s = AppSettings(store);
      // BUG: ThemeMode.values.byName throws ArgumentError on an unknown/renamed value,
      // which makes AppServices.create (and thus app launch) fail for good.
      await s.load();
      expect(s.themeMode, ThemeMode.system);
    });

    test('update notifies listeners once and persists immediately', () async {
      final store = MemoryJsonStore();
      final s = AppSettings(store);
      var n = 0;
      s.addListener(() => n++);
      await s.update((x) => x.thinking = true);
      expect(n, 1);
      expect((await store.read('settings') as Map)['thinking'], true);
    });

    test('keys are trimmed by the UI contract (round trip keeps what is given)', () async {
      final store = MemoryJsonStore();
      final s = AppSettings(store);
      await s.update((x) => x.youtubeKey = 'AIza123');
      expect((await store.read('settings') as Map)['youtubeKey'], 'AIza123');
    });
  });

  // ===================================================================
  group('Ledger', () {
    test('records newest first, caps at 500, persists, counts network events', () async {
      final store = MemoryJsonStore();
      final l = Ledger(store);
      for (var i = 0; i < 520; i++) {
        await l.record('k', 'entry $i', network: i % 10 == 0);
      }
      expect(l.entries.length, 500);
      expect(l.entries.first.detail, 'entry 519');
      expect(l.entries.last.detail, 'entry 20');
      expect(l.networkEvents, l.entries.where((e) => e.network).length);
      final l2 = Ledger(store);
      await l2.load();
      expect(l2.entries.length, 500);
      expect(l2.entries.first.detail, 'entry 519');
      expect(l2.networkEvents, l.networkEvents);
      await l2.clear();
      expect(l2.entries, isEmpty);
      expect(l2.networkEvents, 0);
      expect(await store.read('ledger'), isNull);
    });

    test('legacy entries without the network flag load as non-network', () async {
      final store = MemoryJsonStore();
      await store.write('ledger', [
        {'t': DateTime(2025).toIso8601String(), 'k': 'x', 'd': 'old'},
      ]);
      final l = Ledger(store);
      await l.load();
      expect(l.entries.single.network, isFalse);
    });

    test('unicode and very long details survive a reload', () async {
      final store = MemoryJsonStore();
      final l = Ledger(store);
      final long = 'é漢字🎉' * 5000;
      await l.record('k', long);
      final l2 = Ledger(store);
      await l2.load();
      expect(l2.entries.single.detail, long);
    });
  });

  // ===================================================================
  group('KnowledgeBase', () {
    Future<KnowledgeBase> kb([MemoryJsonStore? store]) async {
      final k = KnowledgeBase(store: store ?? MemoryJsonStore(), embedder: () async => LexicalEmbedder());
      await k.load();
      return k;
    }

    test('chunk: empty, whitespace, short, exact boundary, overlap, huge', () {
      // Blank text has nothing to index (an empty chunk would become an empty document).
      expect(KnowledgeBase.chunk(''), isEmpty);
      expect(KnowledgeBase.chunk('   \n\t '), isEmpty);
      expect(KnowledgeBase.chunk('one two'), ['one two']);
      final w120 = List.generate(120, (i) => 'w$i').join(' ');
      expect(KnowledgeBase.chunk(w120), [w120]);
      final w121 = List.generate(121, (i) => 'w$i').join(' ');
      final c121 = KnowledgeBase.chunk(w121);
      expect(c121.length, 2);
      expect(c121.last.split(' ').first, 'w100', reason: 'overlap of 20 words');
      expect(c121.last.split(' ').last, 'w120');
      // Every word is covered, no chunk beyond 120 words, no empty chunk.
      final huge = List.generate(100000, (i) => 'w$i').join(' ');
      final chunks = KnowledgeBase.chunk(huge);
      expect(chunks.every((c) => c.isNotEmpty && c.split(' ').length <= 120), isTrue);
      expect(chunks.first.startsWith('w0 '), isTrue);
      expect(chunks.last.endsWith('w99999'), isTrue);
      expect(chunks.length, inInclusiveRange(990, 1010));
      // Whitespace-collapsing and unicode.
      expect(KnowledgeBase.chunk('a\n\nb\t c'), ['a b c']);
      expect(KnowledgeBase.chunk('héllo wörld 漢字 🎉'), ['héllo wörld 漢字 🎉']);
    });

    test('add/search/remove/clear and persistence', () async {
      final store = MemoryJsonStore();
      final k = await kb(store);
      expect(await k.search('anything'), isEmpty);
      final n = await k.add('Garden', 'tomatoes need sunlight and water every morning', source: 'notes');
      expect(n, 1);
      await k.add('Cars', 'the engine needs oil changes twice a year');
      expect(k.docs.first.title, 'Cars');
      final hits = await k.search('tomatoes sunlight');
      expect(hits.first['title'], 'Garden');
      expect((hits.first['score'] as double) <= 1.0, isTrue);
      expect(k.textOf(k.docs.last), contains('tomatoes'));

      final k2 = await kb(store);
      expect(k2.docs.length, 2);
      expect((await k2.search('engine oil')).first['title'], 'Cars');

      await k2.remove(k2.docs.first);
      expect(k2.docs.length, 1);
      expect(await k2.search('engine oil'), isEmpty);
      final k3 = await kb(store);
      expect(k3.docs.length, 1);
      await k3.clear();
      expect(k3.docs, isEmpty);
      expect(await store.read('knowledge'), isNull);
      expect(await k3.search('tomatoes'), isEmpty);
    });

    test('multi-chunk documents report chunk count and reassemble text', () async {
      final k = await kb();
      final text = List.generate(300, (i) => 'word$i').join(' ');
      final n = await k.add('Long', text);
      expect(n, greaterThan(2));
      expect(k.docs.first.chunks, n);
      expect(k.textOf(k.docs.first), contains('word299'));
    });

    test('search limit and no-match', () async {
      final k = await kb();
      for (var i = 0; i < 8; i++) {
        await k.add('Doc $i', 'banana smoothie recipe number $i with banana');
      }
      expect((await k.search('banana smoothie', limit: 3)).length, 3);
      expect(await k.search('zzzzqqqq'), isEmpty);
      expect(await k.search(''), isA<List>());
    });

    test('duplicate titles remove only the chosen document', () async {
      final k = await kb();
      await k.add('Same', 'first body about apples');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await k.add('Same', 'second body about oranges');
      await k.remove(k.docs.last);
      expect(k.docs.length, 1);
      expect(k.textOf(k.docs.single), contains('oranges'));
    });

    test('embedder switch re-embeds existing chunks and persists the new key', () async {
      final store = MemoryJsonStore();
      var useSecond = false;
      final first = LexicalEmbedder();
      final second = _Dim64();
      final k = KnowledgeBase(store: store, embedder: () async => useSecond ? second : first);
      await k.add('A', 'apples are red');
      useSecond = true;
      final hits = await k.search('apples red');
      expect(hits, isNotEmpty);
      expect((await store.read('knowledge') as Map)['embedder'], contains('_Dim64'));
    });

    test('mismatched vector length scores 0 instead of throwing', () {
      expect(KnowledgeBase.cosine([1, 2], [1, 2, 3]), 0);
      expect(KnowledgeBase.cosine([0, 0], [0, 0]), 0);
      expect(KnowledgeBase.cosine([1, 0], [1, 0]), closeTo(1, 1e-9));
    });

    test('unicode text round-trips; accented Latin words are findable', () async {
      final store = MemoryJsonStore();
      final k = await kb(store);
      await k.add('Réunion', 'Le café de Zürich 漢字 🎉 naïve');
      final k2 = await kb(store);
      expect(k2.textOf(k2.docs.single), 'Le café de Zürich 漢字 🎉 naïve');
      expect(k2.docs.single.title, 'Réunion');
    });

    test('non-Latin documents can be found by their own words', () async {
      final k = await kb();
      await k.add('日本語', '東京は日本の首都です 桜が咲いています');
      await k.add('Other', 'completely unrelated english words about engines');
      // BUG: both the lexical embedder and the keyword bonus only tokenise [a-z0-9], so any CJK /
      // Cyrillic / Arabic / accented-only query produces a zero vector and finds nothing.
      final hits = await k.search('東京は日本の首都');
      expect(hits, isNotEmpty);
      expect(hits.first['title'], '日本語');
    });

    test('adding blank text should not create an empty document', () async {
      final k = await kb();
      final n = await k.add('Empty', '   ');
      // BUG: chunk('') returns [''] so a blank document with one empty chunk is stored and listed
      // (agent.dart saveToKnowledge passes model-supplied text straight through).
      expect(n, 0);
      expect(k.docs, isEmpty);
    });

    test('huge text is chunked and added in reasonable time', () async {
      final k = await kb();
      final sw = Stopwatch()..start();
      final n = await k.add('Huge', List.generate(60000, (i) => 'token$i').join(' '));
      expect(n, greaterThan(400));
      expect(sw.elapsed.inSeconds, lessThan(20));
    });

    test('load tolerates a store with only docs missing chunks key?', () async {
      final store = MemoryJsonStore();
      await store.write('knowledge', {'docs': [], 'chunks': []});
      final k = await kb(store);
      expect(k.docs, isEmpty);
    });
  });

  // ===================================================================
  group('MemoryStore', () {
    Future<MemoryStore> mem([MemoryJsonStore? s]) async {
      final m = MemoryStore(s ?? MemoryJsonStore());
      await m.load();
      return m;
    }

    test('add trims, ignores blank and case-insensitive duplicates, newest first, persists', () async {
      final store = MemoryJsonStore();
      final m = await mem(store);
      await m.add('  Likes tea ');
      await m.add('likes TEA');
      await m.add('');
      await m.add('   ');
      await m.add('Lives in Zürich 漢字 🎉');
      expect(m.facts.map((f) => f.text), ['Lives in Zürich 漢字 🎉', 'Likes tea']);
      final m2 = await mem(store);
      expect(m2.facts.map((f) => f.text), ['Lives in Zürich 漢字 🎉', 'Likes tea']);
    });

    test('remove / clear / promptBlock cap', () async {
      final m = await mem();
      for (var i = 0; i < 25; i++) {
        await m.add('fact number $i');
      }
      expect(m.promptBlock.split('\n').length, 20);
      expect(m.promptBlock.startsWith('- fact number 24'), isTrue);
      await m.remove(m.facts.first);
      expect(m.facts.length, 24);
      await m.clear();
      expect(m.facts, isEmpty);
      expect(m.promptBlock, '');
    });

    test('recall ranks by shared terms; broad query returns recent facts', () async {
      final m = await mem();
      await m.add('My dog is called Rex');
      await m.add('I work at Taazaa');
      expect(m.recall('what is my dog called').first, 'My dog is called Rex');
      expect(m.recall('hello there'), hasLength(2));
      expect(m.recall('x', limit: 1), hasLength(1));
    });

    test('forget removes the best match, or reports false', () async {
      final m = await mem();
      await m.add('My dog is called Rex');
      await m.add('I work at Taazaa');
      expect(await m.forget('the dog'), isTrue);
      expect(m.facts.single.text, 'I work at Taazaa');
      expect(await m.forget('zzz qqq'), isFalse);
      expect(await m.forget(''), isFalse);
    });

    test('recall/forget on non-Latin facts', () async {
      final m = await mem();
      await m.add('好きな色は青です');
      // BUG (same root cause as knowledge search): _terms only keeps [a-z0-9], so non-Latin facts
      // can never be matched by forget().
      expect(await m.forget('好きな色は青です'), isTrue);
    });
  });

  // ===================================================================
  group('onboarding + shell', () {
    testWidgets('welcome -> setup -> download -> start -> shell', (tester) async {
      final app = await _boot(tester, onboarded: false);
      expect(find.textContaining('your assistant'), findsWidgets);
      expect(find.text('nothing leaves this phone'), findsOneWidget);
      _noError(tester, 'welcome');

      // privacy link then back
      await _tap(tester, find.text('how does privacy work?'));
      expect(find.textContaining('stays'), findsWidgets);
      await _back(tester);
      expect(find.text("let's start"), findsOneWidget);

      await _tap(tester, find.text("let's start"));
      expect(find.textContaining('you decide'), findsWidgets);
      expect(find.text('start · download later'), findsOneWidget);
      expect(find.textContaining('about '), findsWidgets);


      await _tap(tester, find.text('download the models'));
      expect(find.text('downloading, carry on while it runs'), findsOneWidget);
      expect(find.text('start'), findsOneWidget);
      for (final id in ['gemma-4-e2b', 'functiongemma-270m-mobile-actions', 'embeddinggemma-2-text-270m']) {
        expect(app.services.models.state(id).status, ModelStatus.downloading, reason: id);
      }
      await _settle(tester, 3000);
      for (final id in [
        'gemma-4-e2b',
        'functiongemma-270m-mobile-actions',
        'embeddinggemma-2-text-270m',
        'desertant.voz',
        'desertant.who',
        'desertant.redact',
      ]) {
        expect(app.services.models.isReady(id), isTrue, reason: id);
      }
      await _tap(tester, find.text('start'));
      expect(app.services.settings.onboarded, isTrue);
      expect(find.text('record a meeting'), findsOneWidget);
      _noError(tester, 'shell after onboarding');
    });

    testWidgets('start without downloading, nothing downloaded', (tester) async {
      final app = await _boot(tester, onboarded: false);
      await _tap(tester, find.text("let's start"));
      await _tap(tester, find.text('start · download later'));
      expect(app.services.settings.onboarded, isTrue);
      expect(app.services.models.isReady('gemma-4-e2b'), isFalse);
    });

    testWidgets('onboarded state persists across a relaunch', (tester) async {
      final store = MemoryJsonStore();
      await _boot(tester, onboarded: false, store: store);
      await _tap(tester, find.text("let's start"));
      await _tap(tester, find.text('start · download later'));
      final s2 = (await tester.runAsync(() => AppServices.create(store: store, platform: 'demo')))!;
      expect(s2.settings.onboarded, isTrue);
    });

    testWidgets('five tabs, each shows its page, and tab state is kept', (tester) async {
      final app = await _boot(tester);
      expect(find.text('record a meeting'), findsOneWidget);
      for (final (label, marker) in [
        ('saved', 'nothing saved yet'),
        ('skills', 'transcribe audio'),
        ('models', 'the models'),
        ('you', 'privacy'),
        ('chat', 'record a meeting'),
      ]) {
        await _tab(tester, label);
        expect(find.text(marker), findsWidgets, reason: label);
        _noError(tester, 'tab $label');
      }
      expect(app.state.tab, 0);
    });

    testWidgets('"show the welcome again" returns to onboarding', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      await _tap(tester, find.text('show the welcome again'));
      expect(app.services.settings.onboarded, isFalse);
      // The pushed settings route stays above the (rebuilt) shell; pop and check.
      await _back(tester);
      expect(find.textContaining('your assistant'), findsWidgets);
    });
  });

  // ===================================================================
  group('you doors', () {
    final doors = <(String, String)>[
      ('memory', 'nothing remembered'),
      ('my files', 'no files yet'),
      ('privacy', 'what you keep'),
      ('lab', 'prompt lab'),
      ('settings', 'light or dark'),
      ('about', 'open-source licences'),
    ];
    for (final (door, marker) in doors) {
      testWidgets('door "$door" opens its screen and pops back', (tester) async {
        await _boot(tester);
        await _door(tester, door);
        expect(find.textContaining(marker), findsWidgets, reason: door);
        _noError(tester, door);
        await _back(tester);
        expect(find.widgetWithText(Door, door), findsOneWidget);
      });
    }

    testWidgets('door meta counts update with data', (tester) async {
      final app = await _boot(tester, seed: _seedRich);
      await _tab(tester, 'you');
      expect(find.textContaining('2 things you asked'), findsOneWidget);
      expect(find.textContaining('2 documents it can search'), findsOneWidget);
      expect(find.textContaining('3 network events'), findsOneWidget);
      await app.services.memory.add('new fact');
      await _settle(tester, 200);
      expect(find.textContaining('3 things you asked'), findsOneWidget);
    });
  });

  // ===================================================================
  group('settings screen', () {
    testWidgets('theme switch: dark, light, like the phone', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      await _tap(tester, find.text('dark'));
      expect(app.services.settings.themeMode, ThemeMode.dark);
      expect(Theme.of(tester.element(find.text('light or dark'))).brightness, Brightness.dark);
      await _tap(tester, find.text('light'));
      expect(app.services.settings.themeMode, ThemeMode.light);
      expect(Theme.of(tester.element(find.text('light or dark'))).brightness, Brightness.light);
      await _tap(tester, find.text('like the phone'));
      expect(app.services.settings.themeMode, ThemeMode.system);
      _noError(tester, 'theme');
    });

    testWidgets('every handwriting voice selects, persists and renders', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      for (final v in Voice.values) {
        await _tap(tester, find.text(v.label));
        expect(app.services.settings.voice, v.name);
        final row = find.ancestor(of: find.text(v.label).first, matching: find.byType(Row)).first;
        final sample = tester.widget<Text>(find.descendant(of: row, matching: find.text('Nothing you say leaves this phone.')));
        expect(sample.style!.fontFamily, v.family);
        _noError(tester, 'voice ${v.name}');
      }
      final store = app.services.store;
      expect(((await store.read('settings')) as Map)['voice'], Voice.values.last.name);
    });

    testWidgets('every SwitchRow toggles its setting both ways', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      final st = app.services.settings;
      final rows = <(String, bool Function(), String)>[
        ('fast path', () => st.useRouter, 'useRouter'),
        ('read shared links', () => st.readLinks, 'readLinks'),
        ('summarise when shared', () => st.autoSummarise, 'autoSummarise'),
        ('free web reader', () => st.webReader, 'webReader'),
        ('think first', () => st.thinking, 'thinking'),
        ('use the graphics chip', () => st.useGpu, 'useGpu'),
      ];
      for (final (title, get, key) in rows) {
        final before = get();
        await _tap(tester, find.text(title));
        expect(get(), !before, reason: title);
        expect(((await app.services.store.read('settings')) as Map)[key], !before, reason: '$title persisted');
        await _tap(tester, find.text(title));
        expect(get(), before, reason: '$title back');
      }
      _noError(tester, 'switches');
    });

    testWidgets('sliders update creativity and steps', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      final sliders = find.byType(Slider);
      expect(sliders, findsNWidgets(2));
      await tester.drag(sliders.at(0), const Offset(5000, 0));
      await _settle(tester, 200);
      expect(app.services.settings.temperature, closeTo(1.2, 1e-9));
      expect(find.textContaining('creativity · 1.2'), findsOneWidget);
      await tester.drag(sliders.at(0), const Offset(-5000, 0));
      await _settle(tester, 200);
      expect(app.services.settings.temperature, 0.0);
      await tester.drag(sliders.at(1), const Offset(5000, 0));
      await _settle(tester, 200);
      expect(app.services.settings.maxSteps, 12);
      await tester.drag(sliders.at(1), const Offset(-5000, 0));
      await _settle(tester, 200);
      expect(app.services.settings.maxSteps, 1);
      expect(find.text('steps per answer · 1'), findsOneWidget);
    });

    testWidgets('key fields save trimmed values; token reveal toggles', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      final yt = find.widgetWithText(TextField, 'YouTube Data API key (optional)');
      final jina = find.widgetWithText(TextField, 'Jina key (optional)');
      final hf = find.widgetWithText(TextField, 'access token (optional)');
      await tester.enterText(yt, '  AIzaKEY  ');
      await tester.enterText(jina, ' jina_KEY\n');
      await tester.enterText(hf, ' hf_TOKEN ');
      await _settle(tester, 200);
      final st = app.services.settings;
      expect(st.youtubeKey, 'AIzaKEY');
      expect(st.jinaKey, 'jina_KEY');
      expect(st.hfToken, 'hf_TOKEN');
      expect(tester.widget<TextField>(yt).obscureText, isTrue);
      expect(tester.widget<TextField>(hf).obscureText, isTrue);
      await tester.tap(find.byTooltip('Show'));
      await _settle(tester, 200);
      expect(tester.widget<TextField>(hf).obscureText, isFalse);
      await tester.tap(find.byTooltip('Hide'));
      await _settle(tester, 200);
      expect(tester.widget<TextField>(hf).obscureText, isTrue);
      // Clearing the field clears the stored key.
      await tester.enterText(yt, '');
      await _settle(tester, 200);
      expect(st.youtubeKey, '');
      final reloaded = AppSettings(app.services.store);
      await tester.runAsync(reloaded.load);
      expect(reloaded.jinaKey, 'jina_KEY');
      expect(reloaded.hfToken, 'hf_TOKEN');
    });

    testWidgets('stored keys prefill the fields on open', (tester) async {
      await _boot(tester, seed: (s) => s.settings.update((x) {
        x.youtubeKey = 'yt1';
        x.jinaKey = 'jn1';
        x.hfToken = 'hf1';
      }));
      await _door(tester, 'settings');
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'YouTube Data API key (optional)')).controller!.text, 'yt1');
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Jina key (optional)')).controller!.text, 'jn1');
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'access token (optional)')).controller!.text, 'hf1');
    });

    testWidgets('key links are present, tappable and error free', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'settings');
      // The device bridge is a final field of AppServices (not injectable), so the URL passed to
      // url.open cannot be observed here; check the labels are there and tapping is safe, and the
      // exact URLs are asserted against the screen source below.
      for (final label in [
        '1 · turn on the API ↗',
        '2 · create a key ↗',
        'get a free Jina key ↗',
        'create a token (read access) ↗',
        'accept the FunctionGemma licence ↗',
      ]) {
        await _tap(tester, find.text(label), 300);
      }
      await _settle(tester, 400);
      _noError(tester, 'key links');
      expect(app.services.device.isDemo, isTrue);
      final src = File('lib/features/settings/settings_screen.dart').readAsStringSync();
      for (final u in [
        'https://console.cloud.google.com/apis/library/youtube.googleapis.com',
        'https://console.cloud.google.com/apis/credentials',
        'https://jina.ai/api-dashboard/key-manager',
        'https://huggingface.co/settings/tokens/new?tokenType=read',
        'https://huggingface.co/litert-community/functiongemma-270m-ft-mobile-actions',
      ]) {
        expect(src, contains("'$u'"));
      }
      // The licence link must be the same page the model catalog says is gated.
      expect(src, contains(modelById('functiongemma-270m-mobile-actions')!.hfPage!));
    });

    testWidgets('about screen and licence page open', (tester) async {
      await _boot(tester);
      await _door(tester, 'about');
      expect(find.text('gemma'), findsWidgets);
      await _tap(tester, find.text('open-source licences'));
      expect(find.byType(LicensePage), findsOneWidget);
      _noError(tester, 'licences');
    });
  });

  // ===================================================================
  group('models screen', () {
    testWidgets('rows, roles, RAM note, download -> ready -> use -> delete', (tester) async {
      final app = await _boot(tester);
      await _tab(tester, 'models');
      expect(find.text('the models'), findsOneWidget);
      expect(find.textContaining('gemma 4 e2b'), findsWidgets);
      expect(find.text('brain'), findsOneWidget);
      expect(find.text('router'), findsOneWidget);
      expect(find.text('search'), findsOneWidget);
      expect(find.textContaining('0 B on this phone'), findsOneWidget);
      // 8 GB demo device: E4B (10 GB) shows a RAM warning but still offers download.
      expect(find.text('thinks'), findsNothing);
      expect(find.textContaining('needs 10 GB memory'), findsOneWidget);
      expect(find.textContaining('download the 3 recommended'), findsOneWidget);

      final e2b = find.ancestor(of: find.textContaining('gemma 4 e2b ·'), matching: find.byType(ModelTile)).first;
      await _tap(tester, find.descendant(of: e2b, matching: find.text('download')), 200);
      expect(find.textContaining('downloading'), findsWidgets);
      await _settle(tester, 1500);
      expect(app.services.models.isReady('gemma-4-e2b'), isTrue);
      expect(find.text('on this phone'), findsWidgets);
      expect(find.textContaining('download the 2 recommended'), findsOneWidget);

      // second planner -> "use" switches the brain
      await _tap(tester, find.descendant(
          of: find.ancestor(of: find.textContaining('gemma 3 270m ·'), matching: find.byType(ModelTile)).first,
          matching: find.text('download')), 200);
      await _settle(tester, 1500);
      final g3 = find.ancestor(of: find.textContaining('gemma 3 270m ·'), matching: find.byType(ModelTile)).first;
      await _tap(tester, find.descendant(of: g3, matching: find.text('use')));
      expect(app.services.settings.plannerId, 'gemma-3-270m');
      expect(find.text('use'), findsOneWidget, reason: 'now e2b offers "use"');

      // delete asks for confirmation; "not now" keeps it
      await _tap(tester, find.descendant(of: g3, matching: find.byTooltip('Delete')));
      expect(find.text('delete gemma 3 270m?'), findsOneWidget);
      await _tap(tester, find.text('not now'));
      expect(app.services.models.isReady('gemma-3-270m'), isTrue);
      await _tap(tester, find.descendant(of: g3, matching: find.byTooltip('Delete')));
      await _tap(tester, find.text('delete').last);
      expect(app.services.models.isReady('gemma-3-270m'), isFalse);
      expect(find.textContaining('not downloaded yet'), findsWidgets);
      _noError(tester, 'models');
    });

    testWidgets('"download N recommended" starts exactly the missing recommended models', (tester) async {
      final app = await _boot(tester);
      await _tab(tester, 'models');
      await _tap(tester, find.textContaining('recommended'), 200);
      for (final id in ['gemma-4-e2b', 'functiongemma-270m-mobile-actions', 'embeddinggemma-2-text-270m']) {
        expect(app.services.models.state(id).status, ModelStatus.downloading, reason: id);
      }
      expect(app.services.models.state('gemma-4-e4b').status, ModelStatus.absent);
      await _settle(tester, 1500);
      expect(find.textContaining('recommended'), findsNothing);
    });

    // BUG: models_screen.dart counts every missing recommended model but skips those that do not fit.
    testWidgets('recommended button count matches what it will download on a small phone', (tester) async {
      final app = await _boot(tester);
      app.services.models.device = const DeviceProfile(platform: 'demo', totalRamMb: 4000);
      app.services.models.notifyListeners();
      await _tab(tester, 'models');
      final label = find.textContaining('recommended');
      expect(label, findsOneWidget);
      final shown = int.parse(RegExp(r'download the (\d+) recommended').firstMatch(tester.widget<Text>(label).data!)!.group(1)!);
      await _tap(tester, label, 200);
      final started = ['gemma-4-e2b', 'functiongemma-270m-mobile-actions', 'embeddinggemma-2-text-270m']
          .where((id) => app.services.models.state(id).status == ModelStatus.downloading)
          .length;
      // BUG: the button advertises every missing recommended model but silently skips those that
      // don't fit in RAM (Gemma 4 E2B needs 6 GB), so on a 4 GB phone it says 3 and starts 2.
      expect(started, shown);
      await _settle(tester, 1500);
    });

    testWidgets('get-access sheet: token, check, ok, download; links tappable', (tester) async {
      final app = await _boot(tester);
      await _tab(tester, 'models');
      final ctx = tester.element(find.text('the models'));
      showGetAccess(ctx, app.services, modelById('functiongemma-270m-mobile-actions')!);
      await _settle(tester, 500);
      expect(find.text('get access'), findsWidgets);
      expect(find.text('check access'), findsOneWidget);
      await _tap(tester, find.text('1 · model page'), 300);
      await _tap(tester, find.text('2 · make a token'), 300);
      await tester.enterText(find.widgetWithText(TextField, '3 · paste the token (hf_…)'), '  hf_abc  ');
      await _tap(tester, find.text('check access'), 100);
      await _settle(tester, 500);
      expect(app.services.settings.hfToken, 'hf_abc');
      expect(find.textContaining("You're in"), findsOneWidget);
      await _tap(tester, find.text('download functiongemma 270m'), 200);
      expect(app.services.models.state('functiongemma-270m-mobile-actions').status, ModelStatus.downloading);
      await _settle(tester, 1500);
      _noError(tester, 'get access');
    });

    testWidgets('failed gated download shows get access pill', (tester) async {
      // Uses a ModelTile directly with a failed state is not reachable in demo; assert the tile
      // for a gated, absent model in demo offers a plain download (demo has no gate).
      await _boot(tester);
      await _tab(tester, 'models');
      final fg = find.ancestor(of: find.textContaining('functiongemma 270m ·'), matching: find.byType(ModelTile)).first;
      expect(find.descendant(of: fg, matching: find.text('download')), findsOneWidget);
      expect(find.textContaining('needs a free Hugging Face OK'), findsWidgets);
    });
  });

  // ===================================================================
  group('privacy screen', () {
    testWidgets('counts and each forget clears the right store only', (tester) async {
      final app = await _boot(tester, seed: _seedRich);
      final s = app.services;
      await s.settings.update((x) => x.grantedSkills = {'sms'});
      await _door(tester, 'privacy');
      expect(find.text('log lines'), findsOneWidget);
      Finder count(String label) => find.descendant(
          of: find.ancestor(of: find.text(label).last, matching: find.byType(Column)).first, matching: find.byType(Text));
      expect(tester.widgetList<Text>(count('memories')).first.data, '2');
      expect(tester.widgetList<Text>(count('files')).first.data, '2');
      expect(tester.widgetList<Text>(count('chats')).first.data, '1');
      expect(tester.widgetList<Text>(count('saved')).first.data, '1');

      Future<void> forget(String label) async {
        final row = find.ancestor(of: find.text(label).last, matching: find.byType(Row)).first;
        await _tap(tester, find.descendant(of: row, matching: find.text('forget')));
        expect(find.text('forget $label?'), findsOneWidget);
      }

      // cancel does nothing
      await forget('memory');
      await _tap(tester, find.text('not now'));
      expect(s.memory.facts.length, 2);

      await forget('memory');
      await _tap(tester, find.text('forget').last);
      expect(s.memory.facts, isEmpty);
      expect(s.knowledge.docs.length, 2);
      expect(s.conversations.summaries.length, 1);
      expect(s.saved.items.length, 1);
      expect(s.ledger.entries, isNotEmpty);
      expect(find.text('memory forgotten'), findsOneWidget);
      await _settle(tester, 3500);

      await forget('my files index');
      await _tap(tester, find.text('forget').last);
      expect(s.knowledge.docs, isEmpty);
      expect(s.conversations.summaries.length, 1);
      await _settle(tester, 3500);

      await forget('saved posts');
      await _tap(tester, find.text('forget').last);
      expect(s.saved.items, isEmpty);
      expect(s.conversations.summaries.length, 1);
      await _settle(tester, 3500);

      await forget('all chats');
      await _tap(tester, find.text('forget').last);
      expect(s.conversations.summaries, isEmpty);
      expect(await s.store.read('conv/c1'), isNull);
      await _settle(tester, 3500);

      await forget('skill permissions');
      await _tap(tester, find.text('forget').last);
      expect(s.settings.grantedSkills, isEmpty);
      expect(s.ledger.entries, isNotEmpty);
      await _settle(tester, 3500);

      await forget('activity log');
      await _tap(tester, find.text('forget').last);
      expect(s.ledger.entries, isEmpty);
      expect(s.ledger.networkEvents, 0);
      expect(find.text('nothing yet'), findsOneWidget);
      _noError(tester, 'privacy');
    });

    testWidgets('network entries are marked and the request count matches the ledger', (tester) async {
      final app = await _boot(tester, seed: _seedRich);
      await _door(tester, 'privacy');
      final n = app.services.ledger.networkEvents;
      expect(find.textContaining('made $n network requests'), findsOneWidget);
      expect(find.textContaining('used the network'), findsNWidgets(n));
    });
  });

  // ===================================================================
  group('memory + files screens', () {
    testWidgets('memory: add via dialog, duplicate ignored, forget one', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'memory');
      await _tap(tester, find.text('remember something'));
      await tester.enterText(find.byType(TextField), 'Allergic to peanuts');
      await _tap(tester, find.text('Save'));
      expect(find.text('Allergic to peanuts'), findsOneWidget);
      expect(find.text('nothing remembered'), findsNothing);
      await _tap(tester, find.text('remember something'));
      await tester.enterText(find.byType(TextField), 'allergic to PEANUTS');
      await _tap(tester, find.text('Save'));
      expect(app.services.memory.facts.length, 1);
      await _tap(tester, find.text('remember something'));
      await _tap(tester, find.text('Cancel'));
      expect(app.services.memory.facts.length, 1);
      await _tap(tester, find.byTooltip('Forget'));
      expect(app.services.memory.facts, isEmpty);
      expect(find.text('nothing remembered'), findsOneWidget);
    });

    testWidgets('my files: new note, search, open doc, remove', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'my files');
      expect(find.textContaining('searching by keyword'), findsOneWidget);
      await _tap(tester, find.byTooltip('New note'));
      await tester.enterText(find.widgetWithText(TextField, 'Title'), '');
      await tester.enterText(find.widgetWithText(TextField, 'Text'), 'The wifi password is swordfish');
      await _tap(tester, find.text('Save'));
      expect(app.services.knowledge.docs.single.title, 'Note');
      expect(find.text('note'), findsWidgets);

      // blank text note is ignored
      await _tap(tester, find.byTooltip('New note'));
      await tester.enterText(find.widgetWithText(TextField, 'Text'), '   ');
      await _tap(tester, find.text('Save'));
      expect(app.services.knowledge.docs.length, 1);

      await tester.enterText(find.widgetWithText(TextField, 'search every file…'), 'wifi password');
      await _tap(tester, find.byTooltip('Search'), 300);
      expect(find.text('found'), findsOneWidget);
      expect(find.textContaining('% match'), findsOneWidget);

      await _tap(tester, find.widgetWithText(Door, 'note'));
      expect(find.textContaining('swordfish'), findsWidgets);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);

      await _tap(tester, find.byTooltip('Remove'));
      expect(app.services.knowledge.docs, isEmpty);
      expect(find.text('no files yet'), findsOneWidget);
      _noError(tester, 'files');
    });

    testWidgets('my files: searching an empty index and submit via keyboard', (tester) async {
      await _boot(tester);
      await _door(tester, 'my files');
      await tester.enterText(find.widgetWithText(TextField, 'search every file…'), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 300);
      expect(find.text('found'), findsNothing);
      _noError(tester, 'empty search');
    });
  });

  // ===================================================================
  group('lab', () {
    testWidgets('prompt lab runs in demo, templates fill system, sliders move; speed test runs', (tester) async {
      final app = await _boot(tester);
      await _door(tester, 'lab');
      await _tap(tester, find.text('translate'));
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'System instruction')).controller!.text,
          'Translate into French.');
      await _tap(tester, find.text('free'));
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'System instruction')).controller!.text, '');

      // empty prompt: run does nothing
      await _tap(tester, find.text('run'), 200);
      expect(find.text('what it said'), findsNothing);

      await tester.enterText(find.widgetWithText(TextField, 'Prompt'), 'hello there');
      await tester.drag(find.byType(Slider).first, const Offset(3000, 0));
      await _settle(tester, 100);
      expect(find.textContaining('Temperature 1.5'), findsOneWidget);
      await tester.drag(find.byType(Slider).last, const Offset(-3000, 0));
      await _settle(tester, 100);
      expect(find.text('Top-K 1'), findsOneWidget);
      await _tap(tester, find.text('run'), 100);
      await _settle(tester, 4000);
      expect(find.text('what it said'), findsOneWidget);
      expect(find.textContaining('tok/s'), findsWidgets);
      _noError(tester, 'prompt lab');

      await _tap(tester, find.text('speed test'));
      expect(find.text('Demo engine'), findsOneWidget);
      await _tap(tester, find.text('run the speed test'), 100);
      expect(find.textContaining('Prompt 1 of 3'), findsOneWidget);
      await _settle(tester, 6000);
      expect(find.text('run the speed test'), findsOneWidget);
      expect(app.services.ledger.entries.any((e) => e.kind == 'benchmark'), isTrue);
      await _tap(tester, find.text('run the speed test'), 100);
      await _settle(tester, 6000);
      expect(find.text('earlier runs'), findsOneWidget);
      _noError(tester, 'speed test');
    });
  });

  // ===================================================================
  group('voice screen', () {
    testWidgets('opens from chat, shows idle state, tap without mic is handled', (tester) async {
      await _boot(tester);
      await _tap(tester, find.byTooltip('Talk'));
      await _settle(tester, 500);
      expect(find.text('tap to talk'), findsOneWidget);
      expect(find.textContaining('Say it out loud'), findsOneWidget);
      await tester.tap(find.text('tap to talk'), warnIfMissed: false);
      await _settle(tester, 500);
      // no recorder plugin in tests: must show a message rather than crash
      _noError(tester, 'voice tap');
      await _back(tester);
    });
  });

  // ===================================================================
  // BUG (layout, 320 px wide): PillButton (hand.dart:695 Row has no Flexible/ellipsis) overflows for the
  // 'download the N recommended' button on the models tab (6.4 px at 1.0x text, 130 px at 1.6x); the
  // onboarding 'downloading, carry on while it runs' Row (onboarding.dart:~146, Body not in Expanded)
  // overflows 24 px; at 1.6x text the models header Row (models_screen.dart:42) overflows 85 px.
  group('overflow matrix', () {
    final sizes = <(String, Size)>[('320x640', const Size(320, 640)), ('412x915', const Size(412, 915))];
    for (final (sizeName, size) in sizes) {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('all screens in my area at $sizeName ${theme.name}', (tester) async {
          final found = <String>[];
          final app = await _boot(tester, size: size, theme: theme, seed: _seedRich, collect: true);
          // Long names exercise wrapping.
          await app.services.settings.update((x) => x.voice = 'handwritten');
          await _settle(tester, 200);

          for (final label in ['chat', 'saved', 'skills', 'models', 'you']) {
            await _tab(tester, label);
            _collect(tester, '$label tab @$sizeName ${theme.name}', found);
          }
          // models with downloads in progress and ready
          await _tab(tester, 'models');
          await tester.tap(find.textContaining('recommended').first, warnIfMissed: false);
          await _settle(tester, 300);
          _collect(tester, 'models downloading @$sizeName ${theme.name}', found);
          await _settle(tester, 1500);
          _collect(tester, 'models ready @$sizeName ${theme.name}', found);
          // scroll through the models list to build every row
          for (var i = 0; i < 12; i++) {
            await tester.drag(find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).last, const Offset(0, -500));
            await tester.pump(const Duration(milliseconds: 100));
            _collect(tester, 'models scroll $i @$sizeName ${theme.name}', found);
          }
          // get access sheet
          final ctx = tester.element(find.byType(Scaffold).first);
          showGetAccess(ctx, app.services, modelById('gemma-3-270m')!);
          await _settle(tester, 500);
          _collect(tester, 'get access @$sizeName ${theme.name}', found);
          await _back(tester);

          for (final door in ['memory', 'my files', 'privacy', 'lab', 'settings', 'about']) {
            await _door(tester, door);
            _collect(tester, '$door @$sizeName ${theme.name}', found);
            for (var i = 0; i < 6; i++) {
              final sc = find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical);
              if (sc.evaluate().isEmpty) break;
              await tester.drag(sc.last, const Offset(0, -600));
              await tester.pump(const Duration(milliseconds: 100));
              _collect(tester, '$door scroll $i @$sizeName ${theme.name}', found);
            }
            if (door == 'lab') {
              await _tap(tester, find.text('speed test'));
              _collect(tester, 'speed test @$sizeName ${theme.name}', found);
            }
            if (door == 'my files') {
              await _tap(tester, find.byTooltip('New note'));
              _collect(tester, 'new note dialog @$sizeName ${theme.name}', found);
              await _tap(tester, find.text('Cancel'));
              await _tap(tester, find.widgetWithText(Door, 'a really quite long document title that needs wrapping onto lines'));
              _collect(tester, 'doc sheet @$sizeName ${theme.name}', found);
              await tester.tapAt(const Offset(5, 5));
              await _settle(tester);
            }
            if (door == 'memory') {
              await _tap(tester, find.text('remember something'));
              _collect(tester, 'remember dialog @$sizeName ${theme.name}', found);
              await _tap(tester, find.text('Cancel'));
            }
            if (door == 'privacy') {
              await _tap(tester, find.text('forget').first);
              _collect(tester, 'confirm sheet @$sizeName ${theme.name}', found);
              await _tap(tester, find.text('not now'));
            }
            await _back(tester);
          }
          _stopCollect();
        expect(found.toSet(), isEmpty, reason: 'layout errors:\n${found.toSet().join('\n')}');
        });
      }
      testWidgets('onboarding pages at $sizeName (light and dark)', (tester) async {
        final found = <String>[];
        for (final theme in [ThemeMode.light, ThemeMode.dark]) {
          await _boot(tester, size: size, theme: theme, onboarded: false, collect: true);
          _collect(tester, 'welcome @$sizeName ${theme.name}', found);
          await _tap(tester, find.text("let's start"));
          _collect(tester, 'setup @$sizeName ${theme.name}', found);
          await _tap(tester, find.text('download the models'));
          await _settle(tester, 300);
          _collect(tester, 'setup downloading @$sizeName ${theme.name}', found);
          await _settle(tester, 2000);
          await tester.pumpWidget(const SizedBox());
        }
        _stopCollect();
        expect(found.toSet(), isEmpty, reason: 'layout errors:\n${found.toSet().join('\n')}');
      });
    }

    testWidgets('large system text scale does not overflow settings/privacy/models at 320x640', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final found = <String>[];
      await _boot(tester, size: const Size(320, 640), seed: _seedRich, collect: true);
      await _tab(tester, 'models');
      _collect(tester, 'models @1.6x', found);
      for (final door in ['settings', 'privacy', 'memory', 'my files']) {
        await _door(tester, door);
        _collect(tester, '$door @1.6x', found);
        await _back(tester);
      }
      _stopCollect();
        expect(found.toSet(), isEmpty, reason: 'layout errors:\n${found.toSet().join('\n')}');
    });
  });
}

class _Dim64 extends LexicalEmbedder {
  @override
  int get dimensions => 64;
  @override
  Future<List<double>> embed(String text) async {
    final v = List<double>.filled(64, 0);
    for (final w in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1)) {
      v[w.hashCode.abs() % 64] += 1;
    }
    return v;
  }
}
