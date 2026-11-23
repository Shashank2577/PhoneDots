/// One model catalog and one model store for every app on the device.
///
/// ```dart
/// final store = await ModelStore.open(StoreOptions(appId: 'com.showcase.notes', catalog: ModelCatalog()));
/// await store.ensure('gemma-4-e2b');            // downloads once per device, then shared
/// final path = store.pathOf('gemma-4-e2b', 'gemma-4-E2B-it.litertlm');
/// ```
///
/// Where the store lives on each platform, and how sharing works: docs/MODEL_STORE.md.
library;

export 'src/catalog.dart';
export 'src/generated/platform.g.dart';
export 'src/keep_awake.dart';
export 'src/model_spec.dart';
export 'src/model_state.dart';
export 'src/model_store.dart';
