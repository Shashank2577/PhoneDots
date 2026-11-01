# iOS and macOS setup

PhoneDots' native bridges for Apple platforms (Gemma on LiteRT-LM, the Desert Ant specialists, device actions) are the local plugin `packages/phonedots_native`, shared by iOS and macOS. Its Swift package depends on LiteRT-LM and desert-ant-core, so a build fetches and links them; nothing is added to the Runner by hand.

Requirements: Xcode 26 (Swift 6.2, which desert-ant-core needs). An iPhone on iOS 18 or later; a Mac on macOS 14 or later with Apple silicon (desert-ant-core uses Float16, which Intel Macs lack, so the Mac app is arm64 only).

```bash
flutter config --enable-swift-package-manager
flutter pub get
flutter run -d <iphone-or-macos> --release
```

If Xcode complains about Git LFS while resolving packages, set `GIT_LFS_SKIP_SMUDGE=1` (the release builds do).

**Versions.** LiteRT-LM is pinned to exactly 0.18.1: the 0.19.0 tag's Swift wrapper calls a newer C API than the prebuilt binary it downloads, so it doesn't compile. Move up when a release fixes that.

**Shared model store.** iOS: `Runner/Runner.entitlements` asks for the App Group `group.com.showcase.shared`, where every app of the vendor keeps its models (one download per iPhone). Your Apple team needs that group; signed with a free Apple ID (Sideloadly, AltStore) or without the group, PhoneDots keeps its models in its own folder. macOS: the group needs a provisioned team there too, so the Mac app's entitlements leave it out and models stay in the app's container.

**Release builds.** `.github/workflows/apple-build.yml` builds an unsigned `.ipa` (`flutter build ios --release --no-codesign`, Runner.app in a Payload folder) and a Mac `.zip` on GitHub's macOS runners; the release workflow attaches both. Sideloading and first-open steps are in the README.

Build to a physical iPhone: the simulator has no Neural Engine or Metal GPU path for these models.

## Differences from Android

- **Tool calling.** The Swift API only takes compile-time tools, so Dart describes the skills in the prompt and parses calls from the text. Android uses LiteRT-LM's constrained decoding instead.
- **Timers, alarms, volume and opening other apps.** iOS does not allow apps to do these. The skills say so and suggest Siri.
- **Calendar.** Events are written directly through EventKit after the system permission prompt. Android opens the calendar app with the event filled in instead.
- **Share sheet.** iOS needs a Share Extension target, which is not built yet.
- **Extra specialists.** Uhm (filler words) works on iOS and macOS only. Align, Title and Clips are also Apple-only in desert-ant-core, but no skill uses them yet.
- **Mac.** Runs the same bridges as iOS. There's no flashlight or battery reading; sharing copies to the clipboard; timers and alarms aren't available.
