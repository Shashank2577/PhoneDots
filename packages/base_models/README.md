# base_models

One model catalog (`catalog/models.json`, generated into `lib/src/generated/`) and one on-device model store shared by every app on the device: App Group on iOS/macOS, a per-user folder on Windows/Linux, sibling copy over a signature-protected provider on Android, Cache Storage on web. How it works: [`docs/MODEL_STORE.md`](../../docs/MODEL_STORE.md).
