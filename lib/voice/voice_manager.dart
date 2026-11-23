import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import '../core/ledger.dart';
import '../core/settings.dart';
import '../core/storage/json_store.dart';
import '../core/util/downloader.dart';
import 'neural_voice.dart';
import 'speech_text.dart';
import 'voice_catalog.dart';

enum EngineStatus { absent, downloading, unpacking, ready, failed }

/// Downloads and keeps the neural voice engine and the voices people pick.
/// Every download is listed under privacy; nothing is fetched until asked.
class VoiceManager extends ChangeNotifier {
  VoiceManager({
    required this.store,
    required this.settings,
    required this.ledger,
    required this.modelsDir,
    http.Client? client,
    this.supported = true,
  }) : _client = client ?? http.Client();

  final JsonStore store;
  final AppSettings settings;
  final Ledger ledger;
  final String? modelsDir;
  final http.Client _client;

  /// False on platforms without the neural engine (web, tests on desktop).
  final bool supported;

  static const _catalogKey = 'voice-catalog';
  static const _installedKey = 'voices-installed';

  List<VoiceSpec> catalog = [...VoiceCatalog.starter];
  DateTime? catalogFetched;
  EngineStatus engine = EngineStatus.absent;
  double engineProgress = 0;
  String? engineError;
  final Set<String> installed = {};
  final Map<String, double> voiceProgress = {};
  CancelToken? _engineToken;

  String? get voicesDir => modelsDir == null ? null : '$modelsDir/voices';
  String? get engineDir => voicesDir == null ? null : '$voicesDir/${PocketEngine.folder}';
  String? clipPath(String voiceId, Mood mood) =>
      voicesDir == null ? null : '$voicesDir/clips/$voiceId/${mood.name}.wav';

  VoiceSpec? byId(String id) => catalog.where((v) => v.id == id).firstOrNull;

  /// The voice to speak with, or null for the phone's own voice.
  VoiceSpec? get selected {
    if (settings.voiceId == 'system' || engine != EngineStatus.ready) return null;
    final v = byId(settings.voiceId);
    if (v == null || !installed.contains(v.id)) return null;
    if (v.personalUseOnly && !settings.personalUseVoices) return null;
    return v;
  }

  /// Voices offered in the list (personal-use ones only when allowed).
  List<VoiceSpec> get offered => [
    for (final v in catalog)
      if (!v.personalUseOnly || settings.personalUseVoices) v,
  ];

  Future<void> load() async {
    try {
      final c = await store.read(_catalogKey);
      if (c is Map) {
        final list = [
          for (final v in (c['voices'] as List? ?? const []))
            if (v is Map) VoiceSpec.fromJson(Map<String, dynamic>.from(v)),
        ].whereType<VoiceSpec>().toList();
        if (list.isNotEmpty) catalog = list;
        catalogFetched = DateTime.tryParse('${c['fetched']}');
      }
      final i = await store.read(_installedKey);
      if (i is List) installed.addAll(i.whereType<String>());
    } catch (_) {}
    if (supported && engineDir != null && fileExists('${engineDir!}/${PocketEngine.files.first}')) {
      engine = PocketEngine.files.every((f) => fileExists('${engineDir!}/$f'))
          ? EngineStatus.ready
          : EngineStatus.absent;
    }
    notifyListeners();
  }

  /// Fetches the voice list (a small JSON file listing) at most once a week.
  Future<void> refreshCatalog({bool force = false}) async {
    if (!force && catalogFetched != null && DateTime.now().difference(catalogFetched!) < const Duration(days: 7)) {
      return;
    }
    try {
      unawaited(ledger.record('voice', 'Fetched the voice list from huggingface.co', network: true));
      final res = await _client.get(Uri.parse(VoiceCatalog.listingUrl)).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      final list = VoiceCatalog.parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
      if (list.isEmpty) return;
      catalog = list;
      catalogFetched = DateTime.now();
      await store.write(_catalogKey, {
        'fetched': catalogFetched!.toIso8601String(),
        'voices': [for (final v in list) v.toJson()],
      });
      appLog.info('voice', 'voice list loaded', {'voices': list.length});
      notifyListeners();
    } catch (e) {
      appLog.warn('voice', 'voice list not loaded', {'error': '$e'});
    }
  }

  /// Downloads (98 MB) and unpacks the voice engine.
  Future<void> installEngine() async {
    if (!supported || voicesDir == null) {
      engineError = 'Neural voices need the Android or iOS app.';
      engine = EngineStatus.failed;
      notifyListeners();
      return;
    }
    if (engine == EngineStatus.downloading || engine == EngineStatus.unpacking) return;
    engine = EngineStatus.downloading;
    engineProgress = 0;
    engineError = null;
    notifyListeners();
    final archivePath = '${voicesDir!}/${PocketEngine.folder}.tar.bz2';
    _engineToken = CancelToken();
    try {
      unawaited(ledger.record('voice', 'Downloading the voice engine from github.com', network: true));
      appLog.info('voice', 'engine download started');
      await for (final p in downloadFile(
        url: PocketEngine.archiveUrl,
        destPath: archivePath,
        sha256: PocketEngine.archiveSha256,
        token: _engineToken!,
      )) {
        engineProgress = p.fraction;
        notifyListeners();
      }
      engine = EngineStatus.unpacking;
      notifyListeners();
      await extractArchive(archivePath, voicesDir!);
      await deleteFile(archivePath);
      if (!PocketEngine.files.every((f) => fileExists('${engineDir!}/$f'))) {
        throw StateError('The download was incomplete.');
      }
      engine = EngineStatus.ready;
      appLog.info('voice', 'engine ready');
    } catch (e, st) {
      engine = e is DownloadCancelled ? EngineStatus.absent : EngineStatus.failed;
      engineError = e is DownloadCancelled ? null : 'Could not set up the voice engine: $e';
      if (e is! DownloadCancelled) appLog.error('voice', 'engine setup failed', null, e, st);
    }
    notifyListeners();
  }

  void cancelEngine() => _engineToken?.cancel();

  /// Downloads a voice's clips: its normal voice and, for expressive voices,
  /// one clip per mood. About 1 MB each.
  Future<bool> installVoice(VoiceSpec v) async {
    if (voicesDir == null) return false;
    if (v.personalUseOnly && !settings.personalUseVoices) return false;
    voiceProgress[v.id] = 0;
    notifyListeners();
    try {
      final entries = v.clips.entries.toList();
      for (final (i, e) in entries.indexed) {
        final dest = clipPath(v.id, e.key)!;
        if (!fileExists(dest)) {
          await for (final _ in downloadFile(url: e.value, destPath: dest, token: CancelToken())) {}
        }
        voiceProgress[v.id] = (i + 1) / entries.length;
        notifyListeners();
      }
      unawaited(ledger.record('voice', 'Downloaded the voice "${v.name}" from huggingface.co', network: true));
      installed.add(v.id);
      await store.write(_installedKey, installed.toList());
      appLog.info('voice', 'voice installed', {'voice': v.id, 'clips': entries.length});
      return true;
    } catch (e, st) {
      appLog.error('voice', 'voice download failed', {'voice': v.id}, e, st);
      return false;
    } finally {
      voiceProgress.remove(v.id);
      notifyListeners();
    }
  }

  Future<void> removeVoice(VoiceSpec v) async {
    for (final m in v.clips.keys) {
      final p = clipPath(v.id, m);
      if (p != null) await deleteFile(p);
    }
    installed.remove(v.id);
    await store.write(_installedKey, installed.toList());
    if (settings.voiceId == v.id) await settings.update((s) => s.voiceId = 'system');
    notifyListeners();
  }

  /// The clip to imitate for [mood], falling back to the voice's normal clip.
  String? clipFor(VoiceSpec v, Mood mood) {
    final want = settings.expressiveSpeech && v.clips.containsKey(mood) ? mood : Mood.neutral;
    final p = clipPath(v.id, want);
    if (p != null && fileExists(p)) return p;
    return clipPath(v.id, Mood.neutral);
  }
}
