import 'dart:async';

import 'package:base_models/base_models.dart' as bm;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'agent/conversation.dart';
import 'core/app_log.dart';
import 'core/crash_reporter.dart';
import 'core/ledger.dart';
import 'core/models/model_catalog.dart';
import 'core/models/model_manager.dart';
import 'core/models/model_spec.dart';
import 'core/runtime/engine_types.dart';
import 'core/runtime/dart_device_actions.dart';
import 'core/runtime/demo_engines.dart';
import 'core/runtime/engines.dart';
import 'core/runtime/platform_engines.dart';
import 'core/settings.dart';
import 'core/storage/json_store.dart';
import 'knowledge/knowledge_base.dart';
import 'knowledge/memory_store.dart';
import 'saved/link_preview.dart';
import 'saved/saved_store.dart';
import 'saved/summarizer.dart';
import 'saved/web_reader.dart';
import 'skills/skill.dart';
import 'skills/skill_registry.dart';

/// Content shared into the app from another app's share sheet.
class SharedIntake {
  const SharedIntake({this.text = '', this.attachments = const []});
  final String text;
  final List<Attachment> attachments;
}

/// Wires every service once at startup.
class AppServices {
  AppServices._({
    required this.platform,
    required this.store,
    required this.settings,
    required this.ledger,
    required this.llm,
    required this.nativeEmbedder,
    required this.specialists,
    required this.device,
  });

  final String platform;
  final JsonStore store;
  final AppSettings settings;
  final Ledger ledger;
  final LlmEngine llm;
  final Embedder nativeEmbedder;
  final Embedder lexicalEmbedder = LexicalEmbedder();
  final SpecialistEngine specialists;
  final DeviceActions device;
  late final ModelManager models;
  late final SkillRegistry skills;
  late final KnowledgeBase knowledge;
  late final MemoryStore memory;
  late final ConversationStore conversations;
  final ValueNotifier<SharedIntake?> intake = ValueNotifier(null);
  late final LinkPreviewer links;
  late final SavedStore saved;
  late final CrashReporter crashes;
  late final Summarizer summarizer;

  /// Set to a saved item's id when a share lands in "saved", so the UI can show it.
  final ValueNotifier<String?> savedArrived = ValueNotifier(null);

  bool get isDemo => llm.isDemo;

  static String detectPlatform() {
    if (kIsWeb) return 'demo';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      // The Mac app uses the same Swift bridges as iOS (packages/phonedots_native).
      TargetPlatform.macOS => 'macos',
      _ => 'demo',
    };
  }

  static Future<AppServices> create({
    JsonStore? store,
    String? platform,
    http.Client? linkClient,
    @visibleForTesting LlmEngine? llm,
  }) async {
    final p = platform ?? detectPlatform();
    final s = store ?? await JsonStore.open();
    await appLog.open(s.filesDir);
    appLog.info('app', 'started', {'platform': p});
    final settings = AppSettings(s);
    await settings.load();
    final ledger = Ledger(s);
    await ledger.load();
    final native = p != 'demo';
    final services = AppServices._(
      platform: p,
      store: s,
      settings: settings,
      ledger: ledger,
      // LiteRT-LM's Kotlin API exposes dynamic OpenAPI tools; the Swift API
      // only has compile-time tools, so iOS parses calls from text.
      llm: llm ?? (native ? PlatformLlmEngine(nativeTools: p == 'android') : DemoLlmEngine()),
      nativeEmbedder: native ? PlatformEmbedder() : LexicalEmbedder(),
      specialists: native ? PlatformSpecialistEngine() : DemoSpecialistEngine(),
      device: DartDeviceActions(native ? PlatformDeviceActions() : DemoDeviceActions()),
    );
    services.links = LinkPreviewer(client: linkClient);
    services.crashes = CrashReporter(settings: settings, ledger: ledger);
    services.saved = SavedStore(s);
    services.models = ModelManager(
      store: s,
      llm: services.llm,
      embedder: services.nativeEmbedder,
      specialists: services.specialists,
      settings: settings,
      ledger: ledger,
      shared: native ? await _tryOpenSharedModels(settings, services.specialists) : null,
    );
    services.skills = SkillRegistry(store: s, settings: settings, platform: p);
    services.knowledge = KnowledgeBase(store: s, embedder: services.bestEmbedder);
    services.memory = MemoryStore(s);
    services.conversations = ConversationStore(s);
    services.summarizer = Summarizer(
      store: services.saved,
      links: services.links,
      reader: WebReader(client: linkClient),
      settings: settings,
      ledger: ledger,
      ask: ({required system, required prompt, imagePaths = const []}) =>
          services.ask(system: system, prompt: prompt, imagePaths: imagePaths, maxTokens: 1000),
      canSee: () => !services.isDemo && (modelById(settings.plannerId)?.has(ModelCapability.image) ?? false),
      transcribe: native ? services._transcribe : null,
      videoSheet: native ? services._videoSheet : null,
      filesDir: s.filesDir,
      client: linkClient,
    );
    await Future.wait([
      services.saved.load(),
      services.models.init(),
      services.skills.load(),
      services.knowledge.load(),
      services.memory.load(),
      services.conversations.load(),
    ]);
    if (native) services._listenForShares();
    final crash = appLog.lastCrash;
    if (crash != null && services.crashes.enabled) {
      unawaited(services.crashes.send(crash, device: {'platform': p, 'ramMb': services.models.device.totalRamMb}));
    }
    return services;
  }

  /// The base platform's shared model store: models PhoneDots downloads are
  /// usable by the vendor's other apps on this device, and theirs by PhoneDots.
  /// Each of its steps goes to the diagnostics log (tag "store").
  static Future<bm.ModelStore> _openSharedModels(AppSettings settings, SpecialistEngine specialists) async {
    final shared = await bm.ModelStore.open(
      bm.StoreOptions(
        appId: sharedModelsAppId,
        catalog: bm.ModelCatalog(),
        // The Hugging Face token goes to huggingface.co only (exact host, https).
        headersFor: (f) {
          final u = Uri.tryParse(f.url);
          return settings.hfToken.isNotEmpty && u != null && u.scheme == 'https' && u.host == 'huggingface.co'
              ? {'Authorization': 'Bearer ${settings.hfToken}'}
              : const {};
        },
        // Model ids, file names, hosts and HTTP codes only: nothing the user wrote.
        onLog: (line) => line.contains('FAILED') ? appLog.error('store', line) : appLog.info('store', line),
        sdkInstaller: (id, key, dir, progress) async {
          await for (final p in specialists.download(id)) {
            progress(p);
          }
        },
      ),
    );
    sharedModelsPath = shared.location.path;
    appLog.info('store', 'shared model store opened', {'path': shared.location.path, 'scope': shared.location.scope.name});
    if (specialists is PlatformSpecialistEngine) await specialists.attachStore(shared.location.path);
    // Tell sibling apps PhoneDots is still installed; forget apps unseen for half a year.
    await shared.touchClaims();
    await shared.pruneStaleClaims(const Duration(days: 180));
    return shared;
  }

  /// A store that can't open (no plugin, unreadable folder) must not stop the
  /// app: PhoneDots then keeps models in its own folder, as before, and says so.
  static Future<bm.ModelStore?> _tryOpenSharedModels(AppSettings settings, SpecialistEngine specialists) async {
    try {
      return await _openSharedModels(settings, specialists);
    } catch (e, st) {
      appLog.error('store', 'shared model store unavailable; using this app\'s own folder', null, e, st);
      return null;
    }
  }

  /// PhoneDots' id in the shared store's registry (its Android application id).
  static const sharedModelsAppId = 'ai.phonedots.phonedots';

  /// Where the shared model store lives on this device (for the diagnostics header).
  static String? sharedModelsPath;

  static const _uuid = Uuid();

  /// One-off generation with the planner model (summaries, rewrites, sub-tasks).
  Future<String> ask({
    required String system,
    required String prompt,
    List<String> imagePaths = const [],
    List<String> audioPaths = const [],
    int maxTokens = 1024,
  }) async {
    if (!isDemo && !await models.ensurePlanner()) {
      throw NoModelError('Download ${modelById(settings.plannerId)?.name ?? 'Gemma'} in models first.');
    }
    final session = 'sub-${_uuid.v4()}';
    final out = StringBuffer();
    String? error;
    final started = DateTime.now();
    appLog.info('model', 'side task', {'promptChars': system.length + prompt.length, 'images': imagePaths.length});
    await appLog.busy('working on a side task with ${modelById(settings.plannerId)?.name ?? 'Gemma'}');
    // A stuck model is cancelled (which ends its stream) after 150 s of silence.
    var stalled = false;
    Timer arm() => Timer(const Duration(seconds: 150), () {
      stalled = true;
      unawaited(llm.cancel());
    });
    var watchdog = arm();
    final request = GenerationRequest(
      modelId: settings.plannerId,
      sessionId: session,
      systemPrompt: system,
      history: [EngineTurn(role: TurnRole.user, text: prompt, imagePaths: imagePaths, audioPaths: audioPaths)],
      sampler: SamplerSettings(temperature: 0.3, maxTokens: maxTokens),
    );
    await for (final e in llm.generate(request)) {
      watchdog.cancel();
      watchdog = arm();
      if (e is TokenEvent) out.write(e.text);
      if (e is ErrorEvent) error = e.message;
    }
    watchdog.cancel();
    if (stalled) error ??= 'The model stopped responding (no output for 150 seconds).';
    await appLog.idle();
    error == null
        ? appLog.info('model', 'side task done', {'ms': DateTime.now().difference(started).inMilliseconds})
        : appLog.error('model', 'side task failed', {'message': error});
    await llm.resetSession(session);
    if (error != null) throw StateError(error);
    return out.toString().trim();
  }

  Future<String?> _videoSheet(String path) async {
    try {
      final r = await device.invoke('video.frames', {'path': path, 'frames': 6});
      return r['error'] == null ? r['path'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _transcribe(String path) async {
    try {
      final r = await specialists.run('desertant.voz', 'transcribe', {'audioPath': path});
      return r['error'] == null ? r['text'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  /// Links, screenshots and clips go to "saved" and get summarised; plain
  /// text (nothing to save) still opens a chat.
  Future<void> receiveShare({String text = '', String? subject, List<Attachment> attachments = const []}) async {
    appLog.info('share', 'received', {
      'textChars': text.length,
      'hasSubject': subject != null,
      'files': [for (final a in attachments) a.kind],
    });
    var url = LinkPreviewer.findUrls('$text ${subject ?? ''}', max: 1).firstOrNull;
    // A lone bare domain ("example.com/article") is a link too, e.g. typed into "save a link".
    final lone = text.trim();
    if (url == null && RegExp(r'^[\w-]+(\.[\w-]+)*\.[a-zA-Z]{2,}(/\S*)?$').hasMatch(lone)) {
      try {
        url = LinkPreviewer.clean(lone).toString();
      } catch (_) {}
    }
    if (url == null && attachments.isEmpty) {
      intake.value = SharedIntake(
        text: [subject?.trim() ?? '', text.trim()].where((t) => t.isNotEmpty).join('\n'),
        attachments: attachments,
      );
      return;
    }
    final item = await summarizer.addShare(
      text: text,
      subject: subject,
      url: url,
      files: [
        for (final a in attachments) {'path': a.path, 'name': a.name, 'kind': a.kind},
      ],
    );
    savedArrived.value = item.id;
  }

  Future<Embedder> bestEmbedder() async => !isDemo && await models.ensureEmbedder() ? nativeEmbedder : lexicalEmbedder;

  void _listenForShares() {
    Channels.intake.setMethodCallHandler((call) async {
      if (call.method != 'shared') return null;
      final a = Map<String, dynamic>.from(call.arguments as Map);
      final files = (a['files'] as List? ?? const []).cast<Map>();
      await receiveShare(
        text: a['text'] as String? ?? '',
        subject: a['subject'] as String?,
        attachments: [
          for (var i = 0; i < files.length; i++)
            Attachment(
              id: 'a${i + 1}',
              kind: _kindFor('${files[i]['mime']}'),
              path: '${files[i]['path']}',
              name: '${files[i]['name']}',
            ),
        ],
      );
      return null;
    });
    unawaited(Channels.intake.invokeMethod('ready').catchError((_) => null));
  }

  static String _kindFor(String mime) => mime.startsWith('image/')
      ? 'image'
      : mime.startsWith('audio/') || mime.startsWith('video/')
      ? 'audio'
      : 'document';
}
