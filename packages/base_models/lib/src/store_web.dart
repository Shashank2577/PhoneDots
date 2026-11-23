import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:crypto/crypto.dart' as crypto;
import 'package:web/web.dart' as web;

import 'model_spec.dart';
import 'model_state.dart';
import 'model_store.dart';

const _cacheName = 'base-shared-models-v1';
const _registryKey = 'base.sharedModels.registry';

Future<ModelStore> openPlatformStore(StoreOptions options) async {
  final store = WebModelStore(options);
  await store.refresh();
  return store;
}

/// Web: model files live in the browser's Cache Storage. Every app served
/// from the same origin (e.g. apps.example.com/notes/, apps.example.com/talks/)
/// sees the same cache and the same registry, so a model is fetched once.
class WebModelStore extends ModelStore {
  WebModelStore(super.options);

  @override
  final location = const SharedLocation(_cacheName, ShareScope.browser, 'shared by every app on this website, in this browser');

  final _states = <String, ModelState>{};
  final _cancels = <String, web.AbortController>{};
  // Installs cancelled after their request finished (hashing, caching, registering).
  final _cancelled = <String>{};
  final _installing = <String>{};
  final _inflight = <String, Future<void>>{};

  Map<String, dynamic> _readRegistry() {
    final raw = web.window.localStorage.getItem(_registryKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on FormatException {
      return {};
    }
  }

  void _writeRegistry(Map<String, dynamic> reg) => web.window.localStorage.setItem(_registryKey, jsonEncode(reg));

  @override
  ModelState stateOf(String id) => _states[id] ?? ModelState.absent;

  @override
  String pathOf(String id, [String? file]) {
    final spec = catalog.require(id);
    final f = file == null ? spec.files.firstOrNull : spec.files.where((x) => x.name == file).firstOrNull;
    return f?.url ?? '$_cacheName/$id';
  }

  @override
  String? sourceOf(String id) => _readRegistry().containsKey(id) ? 'network' : null;

  @override
  int get bytesOnDisk => _readRegistry().values.fold<int>(0, (s, e) => s + (((e as Map)['bytes'] as int?) ?? 0));

  @override
  Future<void> refresh() async {
    final reg = _readRegistry();
    for (final m in catalog.all) {
      if (_installing.contains(m.id)) continue;
      final e = reg[m.id] as Map?;
      // The browser may have evicted the files while the registry kept the entry.
      final present = e != null && await _cached(m);
      _states[m.id] = !present
          ? ModelState.absent
          : ModelState(ModelStatus.ready, users: ((e['users'] as Map?) ?? const {}).keys.cast<String>().toSet());
    }
    notifyListeners();
  }

  @override
  Set<String> get claimedByThisApp => {
    for (final e in _readRegistry().entries)
      if (catalog.byId(e.key) != null && (((e.value as Map)['users'] as Map?)?.containsKey(options.appId) ?? false)) e.key,
  };

  @override
  Future<void> ensure(String id) => _inflight[id] ??= _ensure(id).whenComplete(() {
    _inflight.remove(id);
  });

  Future<void> _ensure(String id) async {
    final spec = catalog.require(id);
    await refresh();
    if (stateOf(id).isReady && !await _cached(spec)) {
      // The browser evicted a file but the registry still lists the model: start over.
      final reg = _readRegistry()..remove(id);
      _writeRegistry(reg);
      await refresh();
    }
    if (!stateOf(id).isReady) {
      if (spec.source == ModelSource.sdk) throw UnsupportedError('${spec.name} needs its native SDK; it cannot run in a browser.');
      // Files can be cached while the registry entry is missing (the page closed
      // between the two writes); only refuse when something must be fetched.
      if ((options.offline?.call() ?? false) && !await _cached(spec)) throw OfflineException(spec.name);
      final cache = await web.window.caches.open(_cacheName).toDart;
      _installing.add(id);
      _cancelled.remove(id);
      _set(id, const ModelState(ModelStatus.downloading));
      var total = 0;
      try {
        var done = 0;
        for (final f in spec.files) {
          final hit = await cache.match(f.url.toJS).toDart;
          if (hit != null) {
            done += f.bytes ?? 0;
            total += f.bytes ?? 0;
            continue;
          }
          // The cache can change between checks (eviction, another tab): never fetch while offline.
          if (options.offline?.call() ?? false) throw OfflineException(spec.name);
          final received = await _fetchInto(cache, id, f, (received) {
            if (spec.bytes > 0) _set(id, stateOf(id).copyWith(progress: ((done + received) / spec.bytes).clamp(0, 1)));
          });
          done += received;
          total += received;
        }
        // A cancel (or wipe) after the last request still wins: no claim is written.
        if (_cancelled.contains(id)) throw DownloadCancelled();
      } on DownloadCancelled {
        _installing.remove(id);
        _set(id, ModelState.absent);
        rethrow;
      } catch (e) {
        _installing.remove(id);
        _set(id, ModelState(ModelStatus.failed, error: e.toString()));
        rethrow;
      }
      _installing.remove(id);
      // Re-read: another tab may have finished the same install meanwhile; keep its claims.
      final reg = _readRegistry();
      final previous = ((reg[id] as Map?)?['users'] as Map?) ?? const {};
      reg[id] = {'bytes': total, 'users': {...previous}};
      _writeRegistry(reg);
    }
    final reg = _readRegistry();
    ((reg[id] as Map)['users'] as Map)[options.appId] = DateTime.now().toUtc().toIso8601String();
    _writeRegistry(reg);
    await refresh();
  }

  /// Whether every file of [spec] is still in Cache Storage (browsers may evict it).
  Future<bool> _cached(ModelSpec spec) async {
    final cache = await web.window.caches.open(_cacheName).toDart;
    for (final f in spec.files) {
      if (await cache.match(f.url.toJS).toDart == null) return false;
    }
    return true;
  }

  /// Streams [f] from the network straight into Cache Storage, hashing it on
  /// the way, so a multi-gigabyte model never sits in memory. The stream is
  /// pulled at the cache's pace (backpressure), one chunk at a time.
  Future<int> _fetchInto(web.Cache cache, String id, ModelFile f, void Function(int) progress) async {
    final abort = _cancels[id] = web.AbortController();
    final headers = web.Headers();
    // The saved Hugging Face token for gated models, like the native store sends.
    options.headersFor?.call(f).forEach((name, value) => headers.set(name, value));
    final digest = _DigestSink();
    final hash = crypto.sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      final res = await web.window.fetch(f.url.toJS, web.RequestInit(headers: headers, signal: abort.signal)).toDart;
      if (!res.ok || res.body == null) throw StateError('HTTP ${res.status} for ${f.name}');
      final reader = res.body!.getReader() as web.ReadableStreamDefaultReader;
      // Chrome's cache.put does not settle when its body stream fails, so the
      // stream's own failure (network error, cancel) ends the wait instead.
      final failed = Completer<void>();
      abort.signal.onabort = ((web.Event _) {
        if (!failed.isCompleted) failed.completeError(DownloadCancelled());
      }).toJS;
      Future<void> pull(web.ReadableStreamDefaultController c) async {
        final web.ReadableStreamReadResult r;
        try {
          r = await reader.read().toDart;
        } catch (e) {
          if (!failed.isCompleted) failed.completeError(e);
          rethrow;
        }
        if (r.done) {
          c.close();
          return;
        }
        final chunk = r.value as JSUint8Array;
        final bytes = chunk.toDart;
        hash.add(bytes);
        received += bytes.length;
        options.onNetworkBytes?.call(bytes.length);
        progress(received);
        c.enqueue(chunk);
      }

      final source = JSObject()
        ..['pull'] = ((web.ReadableStreamDefaultController c) => pull(c).toJS).toJS
        ..['cancel'] = ((JSAny? reason) => reader.cancel(reason)).toJS;
      await Future.any([cache.put(f.url.toJS, web.Response(web.ReadableStream(source))).toDart, failed.future]);
    } catch (e) {
      if (abort.signal.aborted || _cancelled.contains(id)) throw DownloadCancelled();
      if (e is StateError) rethrow;
      throw StateError('Network error for ${f.name}');
    } finally {
      _cancels.remove(id);
    }
    hash.close();
    final want = f.sha256;
    if (want != null && digest.value.toString() != want) {
      await cache.delete(f.url.toJS).toDart;
      throw ChecksumMismatch(f.name, want, digest.value.toString());
    }
    if (_cancelled.contains(id)) {
      await cache.delete(f.url.toJS).toDart;
      throw DownloadCancelled();
    }
    return received;
  }

  void _set(String id, ModelState s) {
    _states[id] = s;
    notifyListeners();
  }

  @override
  void cancel(String id, {bool discard = false}) {
    // A cancelled cache.put never commits, so there is no partial to discard.
    if (_installing.contains(id)) _cancelled.add(id);
    _cancels[id]?.abort();
  }

  @override
  Future<void> touchClaims() async {
    final reg = _readRegistry();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final e in reg.values.cast<Map>()) {
      final users = e['users'] as Map?;
      if (users != null && users.containsKey(options.appId)) users[options.appId] = now;
    }
    _writeRegistry(reg);
  }

  @override
  Future<void> pruneStaleClaims(Duration maxAge) async {
    final reg = _readRegistry();
    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    for (final e in reg.values.cast<Map>()) {
      (e['users'] as Map?)?.removeWhere((app, seen) {
        final at = DateTime.tryParse('$seen');
        return app != options.appId && at != null && at.isBefore(cutoff);
      });
    }
    _writeRegistry(reg);
    await refresh();
  }

  @override
  Future<void> release(String id) async {
    final cache = await web.window.caches.open(_cacheName).toDart;
    // Read and write the registry with no await in between, so a claim another
    // tab made meanwhile is seen and kept.
    final reg = _readRegistry();
    final e = reg[id] as Map?;
    if (e == null) return;
    (e['users'] as Map).remove(options.appId);
    if ((e['users'] as Map).isEmpty) {
      reg.remove(id);
      _writeRegistry(reg);
      await _deleteUnused(cache, id);
    } else {
      _writeRegistry(reg);
    }
    await refresh();
  }

  @override
  Future<void> deleteEverywhere(String id) async {
    final cache = await web.window.caches.open(_cacheName).toDart;
    _writeRegistry(_readRegistry()..remove(id));
    await _deleteUnused(cache, id);
    await refresh();
  }

  /// Deletes [id]'s cache entries unless the registry (read fresh, per file)
  /// lists the model again or another model shares the URL (the speech packs' tokens.txt).
  Future<void> _deleteUnused(web.Cache cache, String id) async {
    for (final f in catalog.require(id).files) {
      final reg = _readRegistry();
      final stillUsed = {
        for (final other in reg.keys)
          if (catalog.byId(other) != null)
            for (final g in catalog.require(other).files) g.url,
      };
      if (!stillUsed.contains(f.url)) await cache.delete(f.url.toJS).toDart;
    }
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
