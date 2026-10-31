import 'dart:async';

import 'package:base_models/base_models.dart' as bm;
import 'package:flutter/foundation.dart';

import 'agent/conversation.dart';
import 'core/app_log.dart';
import 'core/ledger.dart';
import 'core/models/model_manager.dart';
import 'core/runtime/dart_device_actions.dart';
import 'core/runtime/demo_engines.dart';
import 'core/runtime/engines.dart';
import 'core/runtime/platform_engines.dart';
import 'core/settings.dart';
import 'core/storage/json_store.dart';
import 'core/version.dart';
import 'knowledge/knowledge_base.dart';
import 'knowledge/memory_store.dart';
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
    required this.log,
  });

  final String platform;
  final JsonStore store;
  final AppSettings settings;
  final Ledger ledger;

  /// Step-by-step log for Settings → Logs (models, loads, errors).
  final AppLog log;
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

  bool get isDemo => llm.isDemo;

  static String detectPlatform() {
    if (kIsWeb) return 'demo';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'demo',
    };
  }

  static Future<AppServices> create({JsonStore? store, String? platform}) async {
    final p = platform ?? detectPlatform();
    final s = store ?? await JsonStore.open();
    final settings = AppSettings(s);
    await settings.load();
    final ledger = Ledger(s);
    await ledger.load();
    final log = AppLog(s);
    await log.load();
    log.add('app', 'PhoneDots $appVersion started on $p');
    final native = p != 'demo';
    final services = AppServices._(
      platform: p,
      store: s,
      settings: settings,
      ledger: ledger,
      // LiteRT-LM's Kotlin API exposes dynamic OpenAPI tools; the Swift API
      // only has compile-time tools, so iOS parses calls from text.
      llm: native ? PlatformLlmEngine(nativeTools: p == 'android') : DemoLlmEngine(),
      nativeEmbedder: native ? PlatformEmbedder() : LexicalEmbedder(),
      specialists: native ? PlatformSpecialistEngine() : DemoSpecialistEngine(),
      device: DartDeviceActions(native ? PlatformDeviceActions() : DemoDeviceActions()),
      log: log,
    );
    services.models = ModelManager(
      store: s,
      llm: services.llm,
      embedder: services.nativeEmbedder,
      specialists: services.specialists,
      settings: settings,
      ledger: ledger,
      shared: native ? await _openSharedModels(settings, services.specialists, log) : null,
      log: log,
    );
    services.skills = SkillRegistry(store: s, settings: settings, platform: p);
    services.knowledge = KnowledgeBase(store: s, embedder: services.bestEmbedder);
    services.memory = MemoryStore(s);
    services.conversations = ConversationStore(s);
    await Future.wait([
      services.models.init(),
      services.skills.load(),
      services.knowledge.load(),
      services.memory.load(),
      services.conversations.load(),
    ]);
    if (native) services._listenForShares();
    return services;
  }

  /// The base platform's shared model store: models PhoneDots downloads are
  /// usable by the vendor's other apps on this device, and theirs by PhoneDots.
  static Future<bm.ModelStore> _openSharedModels(AppSettings settings, SpecialistEngine specialists, AppLog log) async {
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
        onLog: (line) => log.add('models', line),
        sdkInstaller: (id, key, dir, progress) async {
          await for (final p in specialists.download(id)) {
            progress(p);
          }
        },
      ),
    );
    log.add('models', 'shared store: ${shared.location.path} (${shared.location.description})');
    if (specialists is PlatformSpecialistEngine) await specialists.attachStore(shared.location.path);
    // Tell sibling apps PhoneDots is still installed; forget apps unseen for half a year.
    await shared.touchClaims();
    await shared.pruneStaleClaims(const Duration(days: 180));
    return shared;
  }

  /// PhoneDots' id in the shared store's registry (its Android application id).
  static const sharedModelsAppId = 'ai.phonedots.phonedots';

  Future<Embedder> bestEmbedder() async => !isDemo && await models.ensureEmbedder() ? nativeEmbedder : lexicalEmbedder;

  void _listenForShares() {
    Channels.intake.setMethodCallHandler((call) async {
      if (call.method != 'shared') return null;
      final a = Map<String, dynamic>.from(call.arguments as Map);
      final files = (a['files'] as List? ?? const []).cast<Map>();
      intake.value = SharedIntake(
        text: a['text'] as String? ?? '',
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
