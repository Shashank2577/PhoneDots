import 'dart:convert';
import 'dart:io';

import 'package:base_models/base_models.dart' as bm;
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/models/model_catalog.dart';
import 'package:phonedots/core/models/model_manager.dart';
import 'package:phonedots/core/runtime/demo_engines.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';

/// A real (non-demo) engine, so ModelManager takes the shared-store path.
class _RealLlm extends DemoLlmEngine {
  @override
  bool get isDemo => false;
}

/// A JsonStore whose legacy models folder is a real temp folder.
class _Store extends MemoryJsonStore {
  _Store(this._models);
  final String _models;
  @override
  String? get modelsDir => _models;
}

void main() {
  test("PhoneDots' models are in the shared catalog, with the same files", () {
    final shared = bm.ModelCatalog();
    for (final m in allModels) {
      final s = shared.byId(m.id);
      expect(s, isNotNull, reason: '${m.id} is missing from the shared catalog');
      if (m.appDownloads) {
        expect(s!.files.single.name, m.fileName, reason: m.id);
        if (m.sha256 != null) expect(s.files.single.sha256, m.sha256, reason: m.id);
      }
    }
  });

  test('models come from the shared store: one copy, released on delete', () async {
    final tmp = Directory.systemTemp.createTempSync('phonedots-shared-');
    final root = Directory('${tmp.path}/store')..createSync();
    // Another app already put gemma-3-270m in the shared store.
    final spec = modelById('gemma-3-270m')!;
    final dir = Directory('${root.path}/${spec.id}')..createSync();
    File('${dir.path}/${spec.fileName}').writeAsBytesSync(List.filled(64, 7));
    File('${root.path}/registry.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'models': {
          spec.id: {
            'files': {
              spec.fileName: {'bytes': 64, 'sha256': spec.sha256, 'source': 'network'},
            },
            'users': {'com.showcase.desertant': DateTime.now().toUtc().toIso8601String()},
          },
        },
      }),
    );
    // A stale download from an older PhoneDots, which doesn't match the catalog.
    final legacy = Directory('${tmp.path}/legacy')..createSync();
    final stale = File('${legacy.path}/${modelById('gemma-4-e2b')!.fileName}')..writeAsStringSync('partial');

    final shared = await bm.ModelStore.open(
      bm.StoreOptions(appId: 'ai.phonedots.phonedots', catalog: bm.ModelCatalog(), rootOverride: root.path, useNativeLocation: false),
    );
    final store = _Store(legacy.path);
    final manager = ModelManager(
      store: store,
      llm: _RealLlm(),
      embedder: LexicalEmbedder(),
      specialists: DemoSpecialistEngine(),
      settings: AppSettings(store),
      ledger: Ledger(store),
      shared: shared,
    );
    await manager.init();

    expect(manager.isReady(spec.id), isTrue, reason: "another app's copy counts");
    expect(manager.pathFor(spec), '${root.path}/${spec.id}/${spec.fileName}');
    await Future<void>.delayed(const Duration(milliseconds: 200)); // The background adoption pass.
    expect(stale.existsSync(), isTrue, reason: "a download that doesn't match the catalog is never deleted on a guess");
    expect(manager.isReady('gemma-4-e2b'), isFalse);

    await shared.ensure(spec.id); // PhoneDots claims it.
    expect(shared.stateOf(spec.id).users, contains('ai.phonedots.phonedots'));
    await manager.delete(spec.id);
    expect(manager.isReady(spec.id), isFalse);
    expect(File(manager.pathFor(spec)!).existsSync(), isTrue, reason: 'the other app still uses it');
    tmp.deleteSync(recursive: true);
  });
}
