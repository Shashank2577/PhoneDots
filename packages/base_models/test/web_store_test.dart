@TestOn('browser')
library;

import 'package:base_models/base_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web store against a real browser: the file is streamed into Cache
/// Storage, verified, shared through the registry, and cancellable.
const _server = r'''
import 'dart:io';
import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final payload = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    req.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', '*');
    if (req.method == 'OPTIONS') return req.response.close();
    if (req.uri.path == '/slow') {
      for (var i = 0; i < 50; i++) {
        req.response.add(payload.sublist(0, 65536));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } else {
      req.response.add(payload);
    }
    await req.response.close();
  });
  channel.sink.add(server.port);
}
''';

void main() {
  late int port;
  final payload = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);

  setUpAll(() async {
    final channel = spawnHybridCode(_server);
    port = (await channel.stream.first) as int;
  });

  ModelSpec spec(String id, String path, {String? sha}) => ModelSpec(
    id: id,
    name: id,
    family: 'test',
    runtime: 'none',
    role: 'test',
    summary: 'test',
    capabilities: const {'text'},
    license: 'test',
    platforms: const {'web'},
    source: ModelSource.file,
    files: [ModelFile('w.bin', 'http://127.0.0.1:$port$path?$id', sha256: sha, bytes: payload.length)],
  );

  Future<ModelStore> open(String app, List<ModelSpec> extra, {void Function(int)? onBytes}) => ModelStore.open(
    StoreOptions(appId: app, catalog: ModelCatalog(extra: extra), onNetworkBytes: onBytes),
  );

  test('streams a file into the cache, verifies it, and shares it with the next app', () async {
    final m = spec('web.ok', '/w', sha: sha256.convert(payload).toString());
    var bytes = 0;
    final a = await open('app.a', [m], onBytes: (n) => bytes += n);
    await a.ensure(m.id);
    expect(a.isReady(m.id), isTrue);
    expect(bytes, payload.length);
    final b = await open('app.b', [m], onBytes: (_) => fail('b must not download'));
    await b.ensure(m.id);
    expect(b.stateOf(m.id).users, {'app.a', 'app.b'});
    await a.release(m.id);
    await b.release(m.id);
  });

  test('a wrong checksum is refused and nothing is cached', () async {
    final m = spec('web.bad', '/w', sha: '0' * 64);
    final a = await open('app.a', [m]);
    await expectLater(a.ensure(m.id), throwsA(isA<ChecksumMismatch>()));
    expect(a.isReady(m.id), isFalse);
  });

  test('cancel stops a download in progress', () async {
    final m = spec('web.slow', '/slow');
    final a = await open('app.a', [m]);
    final run = a.ensure(m.id);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    a.cancel(m.id);
    await expectLater(run, throwsA(isA<DownloadCancelled>()));
    expect(a.isReady(m.id), isFalse);
  });
}
