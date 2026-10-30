# iOS setup

The Swift bridges compile without the model packages: each import is guarded with `canImport`. Until you add the packages, the app reports models as unavailable. Adding them takes a few minutes in Xcode.

Requirements: macOS with Xcode 26 (Swift 6.2), an iPhone on iOS 18 or later (Desert Ant's Core ML models need iOS 18). The deployment target is already set to 18.0.

1. Run `flutter pub get`, then `cd ios && pod install`.
2. Open `ios/Runner.xcworkspace`.
3. **File → Add Package Dependencies…**
   - `https://github.com/google-ai-edge/LiteRT-LM.git`: pick a release from 0.19.0, and add the **LiteRTLM** product to the **Runner** target.
   - `https://github.com/Desert-Ant-Labs/desert-ant-core.git`: pick from 4.2.1, and add the products you want to ship: **Voz, Who, Ear, Clear, Uhm, Redact, Tongue, Emo, Gist, Eye, Moderator**. Each one you leave out is reported as "not included in this build".
4. If Xcode complains about Git LFS while resolving LiteRT-LM, run:

   ```bash
   GIT_LFS_SKIP_SMUDGE=1 xcodebuild -resolvePackageDependencies -workspace ios/Runner.xcworkspace -scheme Runner
   ```

5. Build to a physical device. The simulator has no Neural Engine or Metal GPU path for these models.

## Differences from Android

- **Tool calling.** The Swift API only takes compile-time tools, so Dart describes the skills in the prompt and parses calls from the text. Android uses LiteRT-LM's constrained decoding instead.
- **Timers, alarms, volume and opening other apps.** iOS does not allow apps to do these. The skills say so and suggest Siri.
- **Calendar.** Events are written directly through EventKit after the system permission prompt. Android opens the calendar app with the event filled in instead.
- **Share sheet.** iOS needs a Share Extension target, which is not built yet.
- **Extra specialists.** Uhm (filler words) works on iOS only. Align, Title and Clips are also iOS-only in desert-ant-core, but no skill uses them yet.
