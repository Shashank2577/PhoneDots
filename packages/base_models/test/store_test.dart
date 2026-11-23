import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:base_models/base_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Two "apps" open the same store folder, as two apps on one Mac, PC or
/// iPhone (App Group) do. A tiny local server stands in for Hugging Face.
void main() {
  late HttpServer server;
  late Directory root;
  late List<int> payload;
  var requests = 0;
  var lastRange = '';
  Completer<void>? stall;
  Completer<void>? stallMidway; // Sends half the file, then waits.
  var gzipWhenAsked = false;

  setUp(() async {
    payload = List<int>.generate(300000, (i) => i % 251);
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests++;
      if (stall != null) await stall!.future; // A server that never answers.
      lastRange = req.headers.value(HttpHeaders.rangeHeader) ?? '';
      final m = RegExp(r'bytes=(\d+)-').firstMatch(lastRange);
      final from = m == null ? 0 : int.parse(m[1]!);
      req.response.statusCode = from > 0 ? 206 : 200;
      if (gzipWhenAsked && (req.headers.value(HttpHeaders.acceptEncodingHeader) ?? '').contains('gzip')) {
        req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        req.response.add(gzip.encode(payload.sublist(from)));
        await req.response.close();
        return;
      }
      req.response.contentLength = payload.length - from;
      try {
        var at = from;
        if (stallMidway != null && from < payload.length ~/ 2) {
          at = payload.length ~/ 2;
          req.response.add(payload.sublist(from, at));
          await req.response.flush();
          await stallMidway!.future;
        }
        req.response.add(payload.sublist(at));
        await req.response.close();
      } on Object {
        // The client hung up (a cancel).
      }
    });
    root = await Directory.systemTemp.createTemp('shared-models-');
  });

  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  ModelCatalog catalog({String? sha}) => ModelCatalog(
    extra: [
      ModelSpec(
        id: 'test.tiny',
        name: 'Tiny',
        family: 'test',
        runtime: 'none',
        role: 'test',
        summary: 'A test model',
        capabilities: const {'text'},
        license: 'test',
        platforms: const {'linux'},
        source: ModelSource.file,
        files: [
          ModelFile(
            'weights.bin',
            'http://127.0.0.1:${server.port}/w',
            sha256: sha ?? sha256.convert(payload).toString(),
            bytes: payload.length,
          ),
        ],
      ),
    ],
  );

  Future<ModelStore> open(String appId, {String? sha, bool offline = false, void Function(int)? onBytes}) => ModelStore.open(
    StoreOptions(
      appId: appId,
      catalog: catalog(sha: sha),
      rootOverride: root.path,
      useNativeLocation: false,
      offline: () => offline,
      onNetworkBytes: onBytes,
    ),
  );

  test('a model downloaded by one app is reused by the next without the network', () async {
    var bytes = 0;
    final notes = await open('com.showcase.notes', onBytes: (n) => bytes += n);
    await notes.ensure('test.tiny');
    expect(notes.isReady('test.tiny'), isTrue);
    expect(requests, 1);
    expect(bytes, payload.length);
    expect(notes.sourceOf('test.tiny'), 'network');
    expect(File(notes.pathOf('test.tiny', 'weights.bin')).lengthSync(), payload.length);

    final talks = await open('com.showcase.talks');
    expect(talks.isReady('test.tiny'), isTrue, reason: 'the second app sees the shared copy at once');
    await talks.ensure('test.tiny');
    expect(requests, 1, reason: 'no second download');
    expect(talks.stateOf('test.tiny').users, {'com.showcase.notes', 'com.showcase.talks'});

    final reg = jsonDecode(File('${root.path}/registry.json').readAsStringSync()) as Map;
    expect((reg['models']['test.tiny']['users'] as Map).keys, containsAll(['com.showcase.notes', 'com.showcase.talks']));
  });

  test('files stay until the last app releases the model', () async {
    final a = await open('app.a');
    final b = await open('app.b');
    await a.ensure('test.tiny');
    await b.ensure('test.tiny');
    await a.release('test.tiny');
    expect(File(b.pathOf('test.tiny', 'weights.bin')).existsSync(), isTrue);
    await b.release('test.tiny');
    expect(Directory(b.pathOf('test.tiny')).existsSync(), isFalse);
    await a.refresh();
    expect(a.isReady('test.tiny'), isFalse);
  });

  test('"never go online" blocks a download that is needed', () async {
    final s = await open('app.a', offline: true);
    await expectLater(s.ensure('test.tiny'), throwsA(isA<OfflineException>()));
    expect(requests, 0);
  });

  test('a damaged download is thrown away', () async {
    final s = await open('app.a', sha: '0' * 64);
    await expectLater(s.ensure('test.tiny'), throwsA(isA<ChecksumMismatch>()));
    expect(s.stateOf('test.tiny').status, ModelStatus.failed);
    expect(File('${s.pathOf('test.tiny', 'weights.bin')}.part').existsSync(), isFalse);
  });

  test('an interrupted download resumes from where it stopped', () async {
    final s = await open('app.a');
    final dir = Directory(s.pathOf('test.tiny'))..createSync(recursive: true);
    File('${dir.path}/weights.bin.part').writeAsBytesSync(payload.sublist(0, 100000));
    await s.ensure('test.tiny');
    expect(lastRange, 'bytes=100000-');
    expect(File(s.pathOf('test.tiny', 'weights.bin')).readAsBytesSync(), payload);
  });

  test('a missing file makes the model absent again', () async {
    final s = await open('app.a');
    await s.ensure('test.tiny');
    File(s.pathOf('test.tiny', 'weights.bin')).deleteSync();
    await s.refresh();
    expect(s.isReady('test.tiny'), isFalse);
  });

  test('a model another app deleted after we saw it is installed again, not claimed', () async {
    final a = await open('app.a');
    final b = await open('app.b');
    await a.ensure('test.tiny');
    await b.refresh();
    expect(b.isReady('test.tiny'), isTrue);
    await a.release('test.tiny'); // the last user lets go: files and entry are gone
    await b.ensure('test.tiny'); // b's view was stale; it must not "claim" a missing entry
    expect(b.isReady('test.tiny'), isTrue);
    expect(File(b.pathOf('test.tiny', 'weights.bin')).existsSync(), isTrue);
    expect(b.stateOf('test.tiny').users, {'app.b'});
  });

  test('a bundled SDK model installs offline and is not counted as network', () async {
    var sdkBytes = 0;
    final s = await ModelStore.open(
      StoreOptions(
        appId: 'app.a',
        catalog: ModelCatalog(),
        rootOverride: root.path,
        useNativeLocation: false,
        offline: () => true,
        sdkInstaller: (id, key, dir, progress) async => progress(1),
        onNetworkBytes: (n) => sdkBytes += n,
      ),
    );
    await s.ensure('desertant.tongue');
    expect(s.isReady('desertant.tongue'), isTrue);
    expect(s.sourceOf('desertant.tongue'), 'bundled');
    expect(sdkBytes, 0);
    await expectLater(s.ensure('desertant.ear'), throwsA(isA<OfflineException>()));
  });

  test('bytes an SDK writes into the store count as downloaded', () async {
    var received = 0;
    final s = await ModelStore.open(
      StoreOptions(
        appId: 'app.a',
        catalog: ModelCatalog(),
        rootOverride: root.path,
        useNativeLocation: false,
        onNetworkBytes: (n) => received += n,
        sdkInstaller: (id, key, dir, progress) async => File('$dir/weights').writeAsBytesSync(List.filled(1234, 1)),
      ),
    );
    await s.ensure('desertant.ear');
    expect(received, 1234);
    expect(s.sourceOf('desertant.ear'), 'network');
  });

  test('claims of apps not seen for a long time are pruned; our own never', () async {
    final a = await open('app.a');
    final b = await open('app.b');
    await a.ensure('test.tiny');
    await b.ensure('test.tiny');
    // b was uninstalled long ago: age its claim.
    final reg = File('${root.path}/registry.json');
    final json = jsonDecode(reg.readAsStringSync()) as Map;
    json['models']['test.tiny']['users']['app.b'] = '2020-01-01T00:00:00Z';
    json['models']['test.tiny']['users']['app.a'] = '2020-01-01T00:00:00Z';
    reg.writeAsStringSync(jsonEncode(json));
    await a.pruneStaleClaims(const Duration(days: 180));
    expect(a.stateOf('test.tiny').users, {'app.a'});
    await a.touchClaims();
    final seen = DateTime.parse(((jsonDecode(reg.readAsStringSync()) as Map)['models']['test.tiny']['users'] as Map)['app.a'] as String);
    expect(DateTime.now().toUtc().difference(seen).inMinutes, lessThan(1));
    await a.release('test.tiny');
    expect(Directory(a.pathOf('test.tiny')).existsSync(), isFalse);
  });

  test('per-app SDK weights: one app installing does not make them ready for another', () async {
    var installs = 0;
    Future<ModelStore> sdkStore(String app) => ModelStore.open(
      StoreOptions(
        appId: app,
        catalog: ModelCatalog(),
        rootOverride: root.path,
        useNativeLocation: false,
        sdkWeightsPerApp: true,
        sdkInstaller: (id, key, dir, progress) async {
          installs++;
          Directory(dir).createSync(recursive: true);
        },
      ),
    );
    final a = await sdkStore('app.a');
    await a.ensure('desertant.ear');
    final b = await sdkStore('app.b');
    expect(b.isReady('desertant.ear'), isFalse);
    await b.ensure('desertant.ear');
    expect(installs, 2, reason: 'b ran its own installer');
    expect(b.isReady('desertant.ear'), isTrue);
    expect(b.stateOf('desertant.ear').users, {'app.a', 'app.b'});
  });

  test('per-app SDK weights: a reinstalled app runs the installer again', () async {
    var installs = 0;
    Future<ModelStore> sdkStore(String local) => ModelStore.open(
      StoreOptions(
        appId: 'app.a',
        catalog: ModelCatalog(),
        rootOverride: root.path,
        useNativeLocation: false,
        sdkWeightsPerApp: true,
        appLocalDir: local,
        sdkInstaller: (id, key, dir, progress) async {
          installs++;
          Directory(dir).createSync(recursive: true);
        },
      ),
    );
    final before = Directory.systemTemp.createTempSync('app-local-');
    final a = await sdkStore(before.path);
    await a.ensure('desertant.ear');
    expect(a.isReady('desertant.ear'), isTrue);
    // Uninstall and reinstall: the shared registry stays, the app's own folder is new.
    final after = Directory.systemTemp.createTempSync('app-local-');
    final again = await sdkStore(after.path);
    expect(again.isReady('desertant.ear'), isFalse);
    await again.ensure('desertant.ear');
    expect(installs, 2);
    expect(again.isReady('desertant.ear'), isTrue);
  });

  test('releasing the last claim leaves a model alone while another app installs it', () async {
    final a = await open('app.a');
    await a.ensure('test.tiny');
    // Another process (app) holds the model's download lock, repairing it.
    final script = File(p.join(Directory.systemTemp.createTempSync('lock-holder-').path, 'hold_lock.dart'))
      ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final f = await File(args[0]).open(mode: FileMode.append);
  await f.lock(FileLock.exclusive);
  print('locked');
  await stdin.first;
}
''');
    final holder = await Process.start('dart', [script.path, p.join(a.pathOf('test.tiny'), '.download.lock')]);
    await holder.stdout.transform(utf8.decoder).firstWhere((l) => l.contains('locked'));
    try {
      await a.release('test.tiny');
      expect(a.stateOf('test.tiny').users, isEmpty);
      expect(File(a.pathOf('test.tiny', 'weights.bin')).existsSync(), isTrue, reason: 'the installing app keeps its files');
    } finally {
      holder.stdin.writeln();
      await holder.exitCode;
    }
    // With nobody installing, the last release deletes the files.
    await a.ensure('test.tiny');
    await a.release('test.tiny');
    expect(Directory(a.pathOf('test.tiny')).existsSync(), isFalse);
  });

  test('cancel aborts a request the server never answers', () async {
    final a = await open('app.a');
    stall = Completer<void>();
    final run = a.ensure('test.tiny');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    a.cancel('test.tiny');
    await expectLater(run.timeout(const Duration(seconds: 5)), throwsA(isA<DownloadCancelled>()));
    stall!.complete();
    stall = null;
    // Nothing is left attached to the cancelled install.
    await a.ensure('test.tiny');
    expect(a.isReady('test.tiny'), isTrue);
  });

  test('a claim on a model whose file went missing is still releasable', () async {
    final a = await open('app.a');
    await a.ensure('test.tiny');
    File(a.pathOf('test.tiny', 'weights.bin')).deleteSync();
    await a.refresh();
    expect(a.isReady('test.tiny'), isFalse);
    expect(a.claimedByThisApp, contains('test.tiny'));
    await a.release('test.tiny');
    expect(a.claimedByThisApp, isEmpty);
  });

  test('a host that would gzip the file still gets asked for the file itself', () async {
    gzipWhenAsked = true;
    final a = await open('app.a');
    await a.ensure('test.tiny');
    expect(File(a.pathOf('test.tiny', 'weights.bin')).readAsBytesSync(), payload);
  });

  test('a cancel keeps the partial download to resume; a wipe cancel deletes it', () async {
    final a = await open('app.a');
    final part = File('${a.pathOf('test.tiny', 'weights.bin')}.part');
    Future<void> startAndCancel({required bool discard}) async {
      stallMidway = Completer<void>();
      final run = a.ensure('test.tiny');
      while (!part.existsSync() || part.lengthSync() == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      a.cancel('test.tiny', discard: discard);
      await expectLater(run.timeout(const Duration(seconds: 5)), throwsA(isA<DownloadCancelled>()));
      stallMidway!.complete();
      stallMidway = null;
    }

    await startAndCancel(discard: false);
    expect(part.existsSync(), isTrue, reason: 'kept for a resume');
    part.deleteSync(); // Start over, so the next download stalls midway again.
    await startAndCancel(discard: true);
    expect(part.existsSync(), isFalse, reason: 'wipe leaves no partial behind');
    expect(Directory(a.pathOf('test.tiny')).listSync().map((e) => p.basename(e.path)), isNot(contains('weights.bin')));
  });

  test('files an app downloaded before the store are adopted, not downloaded again', () async {
    final old = File(p.join(Directory.systemTemp.createTempSync('old-').path, 'model.bin'))..writeAsBytesSync(payload);
    final a = await open('app.a');
    expect(await a.adopt('test.tiny', {'weights.bin': old.path}), isTrue);
    expect(a.isReady('test.tiny'), isTrue);
    expect(old.existsSync(), isFalse, reason: 'moved, not copied');
    expect(requests, 0);
    final wrong = File(p.join(old.parent.path, 'wrong.bin'))..writeAsBytesSync([1, 2, 3]);
    await a.release('test.tiny');
    expect(await a.adopt('test.tiny', {'weights.bin': wrong.path}), isFalse);
    expect(wrong.existsSync(), isTrue);
  });

  test('every step is logged, so the logs page shows what passed and what failed', () async {
    final lines = <String>[];
    final a = await ModelStore.open(
      StoreOptions(appId: 'app.a', catalog: catalog(), rootOverride: root.path, useNativeLocation: false, onLog: lines.add),
    );
    await a.ensure('test.tiny');
    expect(lines, containsAllInOrder(['test.tiny: needed', contains('downloading from 127.0.0.1'), 'weights.bin: checksum ok', 'test.tiny: ready (network)']));
    lines.clear();
    final b = await ModelStore.open(
      StoreOptions(appId: 'app.b', catalog: catalog(sha: '0' * 64), rootOverride: Directory.systemTemp.createTempSync('other-').path, useNativeLocation: false, onLog: lines.add),
    );
    await expectLater(b.ensure('test.tiny'), throwsA(isA<ChecksumMismatch>()));
    expect(lines.last, startsWith('test.tiny: FAILED: The download of weights.bin was damaged'));
  });

  test('the shared catalog is valid', () {
    final c = ModelCatalog();
    expect(c.all.length, greaterThan(20));
    expect(c.byId('gemma-4-e2b')!.files.single.sha256, hasLength(64));
    expect(c.byId('desertant.voz')!.source, ModelSource.sdk);
  });
}
