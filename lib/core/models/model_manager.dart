import 'dart:async';

import 'package:base_models/base_models.dart' as bm;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_log.dart';
import '../ledger.dart';
import '../runtime/engine_types.dart';
import '../runtime/engines.dart';
import '../settings.dart';
import '../storage/json_store.dart';
import '../util/downloader.dart';
import '../util/format.dart';
import 'model_catalog.dart';
import 'model_spec.dart';

enum ModelStatus { absent, downloading, ready, failed }

/// Whether this phone may download a gated model right now.
enum Access { ok, needsToken, badToken, needsLicence, unknown }

/// Maps Hugging Face's answer for a gated file to what the user must do.
Access classifyAccess(int status, {required bool hasToken}) => switch (status) {
  200 || 206 || 302 || 303 || 307 => Access.ok,
  401 => hasToken ? Access.badToken : Access.needsToken,
  403 => hasToken ? Access.needsLicence : Access.needsToken,
  _ => Access.unknown,
};

class ModelState {
  const ModelState(this.status, {this.progress = 0, this.error, this.inSibling = false, this.busyElsewhere = false});

  final ModelStatus status;
  final double progress;
  final String? error;

  /// Not on this app's shelf yet, but another app on this phone has it:
  /// getting it is a copy, with no download.
  final bool inSibling;

  /// Another app on this device is downloading it right now.
  final bool busyElsewhere;
}

/// Owns model files and which models are loaded. Acts as the resource
/// governor: one planner at a time, and never E4B alongside heavy
/// specialists on phones under 8 GB.
///
/// Model files live in the base platform's shared model store ([shared]):
/// one copy per device for every app of the vendor (an App Group folder on
/// iOS; on Android each app's copy, handed over by sibling apps instead of
/// downloaded again). [shared] is null in demo mode and on the web.
class ModelManager extends ChangeNotifier {
  ModelManager({
    required this.store,
    required this.llm,
    required this.embedder,
    required this.specialists,
    required this.settings,
    required this.ledger,
    this.shared,
    http.Client? client,
  }) : _http = client ?? http.Client() {
    shared?.addListener(_mirrorShared);
  }

  final http.Client _http;

  final JsonStore store;

  /// Model steps for the diagnostics log (ids and sizes only).
  void _log(String message) => message.contains('FAILED') ? appLog.error('model', message) : appLog.info('model', message);
  final LlmEngine llm;
  final Embedder embedder;
  final SpecialistEngine specialists;
  final AppSettings settings;
  final Ledger ledger;
  final bm.ModelStore? shared;

  final Map<String, ModelState> _states = {};
  final Map<String, CancelToken> _tokens = {};
  DeviceProfile device = const DeviceProfile(platform: 'unknown', totalRamMb: 0);
  String? loadedPlanner;
  String? loadedRouter;
  String? loadingModel;
  String? loadError;

  static const _demoKey = 'demo-downloads';
  Set<String> _demoDownloaded = {};

  bool get isDemo => llm.isDemo;

  ModelState state(String id) => _states[id] ?? const ModelState(ModelStatus.absent);

  bool isReady(String id) => state(id).status == ModelStatus.ready;

  List<ModelSpec> get visibleModels => allModels.where((m) => m.supports(device.platform)).toList();

  /// Whether [m] goes through the shared store (it is in the shared catalog).
  bool _inStore(ModelSpec m) => shared != null && shared!.catalog.byId(m.id) != null;

  /// Where PhoneDots kept downloads before the shared store.
  String? _legacyPath(ModelSpec m) =>
      store.modelsDir == null || m.fileName == null ? null : '${store.modelsDir}/${m.fileName}';

  String? pathFor(ModelSpec m) {
    if (m.fileName == null) return null;
    return _inStore(m) ? shared!.pathOf(m.id, m.fileName) : _legacyPath(m);
  }

  Future<void> init() async {
    device = await llm.deviceProfile();
    _demoDownloaded = {...((await store.read(_demoKey) as List?) ?? const []).cast<String>()};
    for (final m in allModels) {
      _states[m.id] = ModelState(await _isOnDisk(m) ? ModelStatus.ready : ModelStatus.absent);
      // Desert Ant weights the SDK already has but the store doesn't list yet
      // (installed by an older PhoneDots): register them, so other apps see them.
      if (_inStore(m) && !m.appDownloads && isReady(m.id) && !shared!.isReady(m.id)) {
        unawaited(shared!.ensure(m.id).catchError((Object _) {}));
      }
    }
    _mirrorShared();
    // Checking old files hashes gigabytes: in the background, not before the first frame.
    if (shared != null) unawaited(_adoptAllLegacy());
  }

  Future<void> _adoptAllLegacy() async {
    for (final m in allModels) {
      if (!_inStore(m) || !m.appDownloads) continue;
      try {
        if (await _adoptLegacy(m)) _set(m.id, const ModelState(ModelStatus.ready));
      } catch (_) {
        // Left where it is; the model downloads into the store when next needed.
      }
    }
  }

  /// A model file downloaded before the shared store moves into it when it
  /// matches the catalog (size and SHA-256), so the update downloads nothing.
  /// A file that doesn't match stays where it is (never delete gigabytes on a
  /// guess); it goes once the model is in the store.
  Future<bool> _adoptLegacy(ModelSpec m) async {
    final old = _legacyPath(m);
    if (old == null || !fileExists(old) || shared!.isReady(m.id)) return false;
    return shared!.adopt(m.id, {m.fileName!: old});
  }

  Future<bool> _isOnDisk(ModelSpec m) async {
    if (isDemo) return _demoDownloaded.contains(m.id);
    if (m.appDownloads) return _inStore(m) ? shared!.isReady(m.id) : fileExists(pathFor(m)!);
    try {
      return await specialists.isDownloaded(m.id);
    } catch (_) {
      return false;
    }
  }

  /// Copies the store's live state (progress, sibling copies, another app
  /// downloading) onto PhoneDots' own model states.
  void _mirrorShared() {
    final s = shared;
    if (s != null) {
      for (final m in allModels) {
        if (!_inStore(m)) continue;
        final mine = state(m.id);
        final theirs = s.stateOf(m.id);
        if (mine.status == ModelStatus.downloading) {
          _states[m.id] = ModelState(
            ModelStatus.downloading,
            progress: theirs.status == bm.ModelStatus.downloading ? theirs.progress : mine.progress,
            busyElsewhere: theirs.busyElsewhere,
          );
        } else if (mine.status == ModelStatus.absent || mine.status == ModelStatus.failed) {
          _states[m.id] = ModelState(mine.status, error: mine.error, inSibling: theirs.inSibling);
        }
      }
    }
    notifyListeners();
  }

  int get storageUsed => allModels.where((m) => isReady(m.id)).fold(0, (sum, m) {
    final p = pathFor(m);
    final onDisk = p == null ? 0 : fileSize(p);
    return sum + (onDisk > 0 ? onDisk : m.approxBytes);
  });

  /// Models this phone can comfortably run.
  bool fits(ModelSpec m) => device.totalRamMb == 0 || m.minRamMb <= device.totalRamMb;

  /// Asks Hugging Face (without downloading) whether the saved token may
  /// fetch [m]. One small request, logged in the privacy ledger.
  Future<Access> checkAccess(ModelSpec m) async {
    if (isDemo || !m.gated) return Access.ok;
    final hasToken = settings.hfToken.isNotEmpty;
    try {
      final req = http.Request('GET', Uri.parse(m.downloadUrl!))
        ..followRedirects = false
        ..headers['Range'] = 'bytes=0-0';
      if (hasToken) req.headers['Authorization'] = 'Bearer ${settings.hfToken}';
      final res = await _http.send(req).timeout(const Duration(seconds: 15));
      await res.stream.drain<void>();
      unawaited(ledger.record('download', 'Checked access to ${m.name}', network: true));
      return classifyAccess(res.statusCode, hasToken: hasToken);
    } catch (_) {
      return Access.unknown;
    }
  }

  /// Gated models need a token first; skip them in bulk downloads until then.
  bool canTryDownload(ModelSpec m) => isDemo || !m.gated || settings.hfToken.isNotEmpty;

  Future<void> download(String id) async {
    final m = modelById(id)!;
    if (state(id).status == ModelStatus.downloading) return;
    // A copy from a sibling app is not a download: no network in the ledger.
    final copy = state(id).inSibling;
    if (!copy && !canTryDownload(m)) {
      _set(id, const ModelState(ModelStatus.failed, error: 'needs a free Hugging Face OK: tap "get access"'));
      return;
    }
    _set(id, const ModelState(ModelStatus.downloading));
    _log('${m.id}: ${copy ? 'copy from another app' : 'download'} started (${formatBytes(m.approxBytes)})');
    unawaited(ledger.record('download', '${copy ? 'Copying' : 'Started'} ${m.name} (${formatBytes(m.approxBytes)})', network: !copy));
    try {
      if (isDemo) {
        await for (final p in specialists.download(id)) {
          _set(id, ModelState(ModelStatus.downloading, progress: p));
        }
        _demoDownloaded.add(id);
        await store.write(_demoKey, _demoDownloaded.toList());
      } else if (_inStore(m)) {
        // A copy from a sibling app when one has it; else a resumable, verified
        // download (Desert Ant models through their SDK, into the store).
        await shared!.ensure(id);
        if (!m.appDownloads && !await specialists.isDownloaded(id)) {
          throw StateError('${m.name} did not finish installing');
        }
        // A copy from before the store that didn't match the catalog is no longer needed.
        final old = m.appDownloads ? _legacyPath(m) : null;
        if (old != null && fileExists(old)) await deleteFile(old);
      } else if (m.appDownloads) {
        final token = _tokens[id] = CancelToken();
        final headers = settings.hfToken.isEmpty ? <String, String>{} : {'Authorization': 'Bearer ${settings.hfToken}'};
        await for (final p in downloadFile(
          url: m.downloadUrl!,
          destPath: pathFor(m)!,
          sha256: m.sha256,
          headers: headers,
          token: token,
        )) {
          _set(id, ModelState(ModelStatus.downloading, progress: p.fraction));
        }
      } else {
        await for (final p in specialists.download(id)) {
          _set(id, ModelState(ModelStatus.downloading, progress: p));
        }
      }
      _set(id, const ModelState(ModelStatus.ready));
      final source = _inStore(m) ? shared!.sourceOf(id) : 'network';
      _log('${m.id}: ready (${source ?? 'installed'})');
      if (source == 'sibling') {
        unawaited(ledger.record('download', 'Copied ${m.name} from another app on this phone, no download'));
      } else {
        unawaited(ledger.record('download', 'Finished ${m.name}', network: true));
      }
    } on DownloadCancelled {
      _log('${m.id}: cancelled');
      _set(id, const ModelState(ModelStatus.absent));
    } on bm.DownloadCancelled {
      _log('${m.id}: cancelled');
      _set(id, const ModelState(ModelStatus.absent));
    } catch (e) {
      _log('${m.id}: FAILED: ${_friendly(e)} ($e)');
      _set(id, ModelState(ModelStatus.failed, error: _friendly(e)));
      unawaited(ledger.record('download', 'Failed ${m.name}: ${_friendly(e)}', network: true));
    } finally {
      _tokens.remove(id);
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('HTTP 401')) {
      return settings.hfToken.isEmpty
          ? 'needs a free Hugging Face OK: tap "get access"'
          : 'Hugging Face didn\'t accept the token. Check it under "get access".';
    }
    if (s.contains('HTTP 403')) return 'accept Google\'s licence on the model page first: tap "get access"';
    return s.replaceFirst('Exception: ', '');
  }

  void cancel(String id) {
    _tokens[id]?.cancel();
    shared?.cancel(id);
  }

  Future<void> delete(String id) async {
    final m = modelById(id)!;
    if (loadedPlanner == id || loadedRouter == id) await llm.unload(id);
    if (loadedPlanner == id) loadedPlanner = null;
    if (loadedRouter == id) loadedRouter = null;
    if (isDemo) {
      _demoDownloaded.remove(id);
      await store.write(_demoKey, _demoDownloaded.toList());
    } else if (_inStore(m)) {
      // PhoneDots stops using it; the files go only if no other app uses them.
      await shared!.release(id);
    } else if (m.appDownloads) {
      await deleteFile(pathFor(m)!);
    }
    _set(id, const ModelState(ModelStatus.absent));
    _mirrorShared();
    _log('${m.id}: deleted');
    unawaited(ledger.record('model', 'Deleted ${m.name}'));
  }

  /// Loads the configured planner, unloading any other planner first.
  Future<bool> ensurePlanner() => _ensure(settings.plannerId, isRouter: false);

  Future<bool> ensureRouter() => _ensure(settings.routerId, isRouter: true);

  Future<bool> ensureEmbedder() async {
    if (embedder.isReady) return true;
    final m = modelById(settings.embedderId);
    if (m == null || !isReady(m.id)) return false;
    try {
      final started = DateTime.now();
      _log('${m.id}: loading embedder');
      await embedder.load(modelId: m.id, path: pathFor(m) ?? m.id);
      _log('${m.id}: embedder loaded in ${formatMs(DateTime.now().difference(started).inMilliseconds)}');
      return true;
    } catch (e) {
      _log('${m.id}: embedder FAILED to load: $e');
      loadError = '$e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> _ensure(String id, {required bool isRouter}) async {
    final current = isRouter ? loadedRouter : loadedPlanner;
    if (current == id && llm.isLoaded(id)) return true;
    final m = modelById(id);
    if (m == null || !isReady(id)) return false;
    loadingModel = id;
    loadError = null;
    notifyListeners();
    try {
      if (current != null) await llm.unload(current);
      final lowMemory = device.totalRamMb > 0 && device.totalRamMb < 8000;
      if (!isRouter && lowMemory && m.minRamMb >= 10000 && loadedRouter != null) {
        await llm.unload(loadedRouter!);
        loadedRouter = null;
      }
      final started = DateTime.now();
      appLog.info('model', 'loading ${m.name}', {
        'gpu': settings.useGpu,
        'ramMb': device.totalRamMb,
        'router': isRouter,
      });
      await appLog.busy('loading ${m.name}');
      await llm.load(
        modelId: id,
        path: pathFor(m) ?? id,
        backend: settings.useGpu ? ComputeBackend.gpu : ComputeBackend.cpu,
        maxTokens: isRouter ? 1024 : 4096,
        vision: m.has(ModelCapability.image),
        audio: m.has(ModelCapability.audio),
      );
      if (isRouter) {
        loadedRouter = id;
      } else {
        loadedPlanner = id;
      }
      _log('$id: loaded in ${formatMs(DateTime.now().difference(started).inMilliseconds)}');
      unawaited(
        ledger.record('model', 'Loaded ${m.name} in ${formatMs(DateTime.now().difference(started).inMilliseconds)}'),
      );
      appLog.info('model', 'loaded ${m.name}', {'ms': DateTime.now().difference(started).inMilliseconds});
      await appLog.idle();
      return true;
    } catch (e, st) {
      await appLog.idle();
      appLog.error('model', 'could not load ${m.name}', {'gpu': settings.useGpu}, e, st);
      loadError = 'Could not load ${m.name}: $e';
      return false;
    } finally {
      loadingModel = null;
      notifyListeners();
    }
  }

  void _set(String id, ModelState s) {
    _states[id] = s;
    notifyListeners();
  }

  @override
  void dispose() {
    shared?.removeListener(_mirrorShared);
    super.dispose();
  }
}
