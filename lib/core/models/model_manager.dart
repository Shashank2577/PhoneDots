import 'dart:async';

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
  const ModelState(this.status, {this.progress = 0, this.error});

  final ModelStatus status;
  final double progress;
  final String? error;
}

/// Owns model files and which models are loaded. Acts as the resource
/// governor: one planner at a time, and never E4B alongside heavy
/// specialists on phones under 8 GB.
class ModelManager extends ChangeNotifier {
  ModelManager({
    required this.store,
    required this.llm,
    required this.embedder,
    required this.specialists,
    required this.settings,
    required this.ledger,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final http.Client _http;

  final JsonStore store;
  final LlmEngine llm;
  final Embedder embedder;
  final SpecialistEngine specialists;
  final AppSettings settings;
  final Ledger ledger;

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

  String? pathFor(ModelSpec m) =>
      store.modelsDir == null || m.fileName == null ? null : '${store.modelsDir}/${m.fileName}';

  Future<void> init() async {
    device = await llm.deviceProfile();
    _demoDownloaded = {...((await store.read(_demoKey) as List?) ?? const []).cast<String>()};
    for (final m in allModels) {
      _states[m.id] = ModelState(await _isOnDisk(m) ? ModelStatus.ready : ModelStatus.absent);
    }
    notifyListeners();
  }

  Future<bool> _isOnDisk(ModelSpec m) async {
    if (isDemo) return _demoDownloaded.contains(m.id);
    if (m.appDownloads) return fileExists(pathFor(m)!);
    try {
      return await specialists.isDownloaded(m.id);
    } catch (_) {
      return false;
    }
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
    if (!canTryDownload(m)) {
      _set(id, const ModelState(ModelStatus.failed, error: 'needs a free Hugging Face OK: tap "get access"'));
      return;
    }
    _set(id, const ModelState(ModelStatus.downloading));
    unawaited(ledger.record('download', 'Started ${m.name} (${formatBytes(m.approxBytes)})', network: true));
    try {
      if (isDemo) {
        await for (final p in specialists.download(id)) {
          _set(id, ModelState(ModelStatus.downloading, progress: p));
        }
        _demoDownloaded.add(id);
        await store.write(_demoKey, _demoDownloaded.toList());
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
      unawaited(ledger.record('download', 'Finished ${m.name}', network: true));
    } on DownloadCancelled {
      _set(id, const ModelState(ModelStatus.absent));
    } catch (e) {
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

  void cancel(String id) => _tokens[id]?.cancel();

  Future<void> delete(String id) async {
    final m = modelById(id)!;
    if (loadedPlanner == id || loadedRouter == id) await llm.unload(id);
    if (loadedPlanner == id) loadedPlanner = null;
    if (loadedRouter == id) loadedRouter = null;
    if (isDemo) {
      _demoDownloaded.remove(id);
      await store.write(_demoKey, _demoDownloaded.toList());
    } else if (m.appDownloads) {
      await deleteFile(pathFor(m)!);
    }
    _set(id, const ModelState(ModelStatus.absent));
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
      await embedder.load(modelId: m.id, path: pathFor(m) ?? m.id);
      return true;
    } catch (e) {
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
}
