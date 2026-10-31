---
name: base-platform
description: Keep PhoneDots in step with the base platform (the baseApp repo), whose model hub and on-device engines came from PhoneDots, and move PhoneDots onto its shared packages. Use when changing PhoneDots' model catalog, downloader, engines, native bridges or theme, or when baseApp's catalog or design changed.
---

# PhoneDots and the base platform

`baseApp` (checked out next to this one) is the Flutter monorepo every new app is built on. Much of it came from here:

| PhoneDots | baseApp |
| --- | --- |
| `lib/core/models/*` (catalog, manager), `lib/core/util/downloader*` | `packages/base_models`: one catalog and a model store **shared by every app on the device** |
| `lib/core/runtime/*` (engines, demo, platform channels) | `packages/base_ai` (channels renamed `base/…`) |
| `android/…/LlmBridge.kt`, `SpecialistBridge.kt`, `AudioFiles.kt`, `ios/Runner/*Bridge.swift` | `packages/base_ai_native` (Desert Ant weights go into the shared store) |
| `lib/core/storage/*` | `packages/base_core` (`JsonStore`) |
| `lib/theme/*`, `lib/widgets/sketch.dart` | superseded by `packages/base_design` (Burrow's system) |

## Synced files

`baseApp/./base sync` writes:

- `assets/base/models.json`: the shared catalog (same ids as `model_catalog.dart`, plus the speech packs, all with SHA-256s and sizes);
- `lib/theme/base_tokens.g.dart`: the platform's design tokens (not used yet).

When you change `lib/core/models/model_catalog.dart`, make the same change in `baseApp/catalog/models.json` (then `./base checksums`, `./base gen`), or the next sync shows the drift.

## A fix made here

A fix in code that baseApp also has (downloader, engines, bridges, the JSON store) belongs in baseApp too, or the other apps keep the bug. Port it, then follow baseApp's `propagate-change` skill.

## Moving PhoneDots onto the platform

The goal is for PhoneDots to depend on the packages and get every change automatically. In order:

1. Add PhoneDots to the workspace: move it to `baseApp/apps/phonedots` (or reference the packages by path) with `resolution: workspace`.
2. Replace `ModelManager` + `downloader` with `ModelStore` (`base_models`): `ensure`, `pathOf`, `stateOf`. Gemma files then live in the shared store, so a Gemma downloaded by any app is reused here.
3. Replace `lib/core/runtime` with `base_ai` and the native bridges with `base_ai_native`; rename channels `phonedots/*` → `base/*` (the agent, skills and intake channel stay app code).
4. Adopt `base_core`'s shell for onboarding, settings, models and privacy, and `base_design` for the look, then delete `lib/theme` and `lib/widgets/sketch.dart`.
5. Keep PhoneDots-specific parts in the app: agent loop, 58 skills, recipes, community skills, voice mode, knowledge base.
6. Run `flutter analyze`, `flutter test` and baseApp's `./base check`.
