// swift-tools-version: 5.9

import PackageDescription

// PhoneDots' native bridges, shared by iOS and macOS. The on-device AI SDKs are
// dependencies of this target, so `flutter build ios|macos` (Swift Package
// Manager) fetches and links them; nothing is added to the Runner by hand.
let package = Package(
    name: "phonedots_native",
    platforms: [
        .iOS("18.0"),
        // desert-ant-core's floor is macOS 14 (LiteRT-LM's is 12).
        .macOS("14.0"),
    ],
    products: [
        .library(name: "phonedots-native", targets: ["phonedots_native"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Exactly 0.18.1: the 0.19.0 tag's Swift wrapper calls a newer C API than
        // the prebuilt v0.18.1 binary it downloads, so it doesn't compile.
        .package(url: "https://github.com/google-ai-edge/LiteRT-LM.git", exact: "0.18.1"),
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.1"),
    ],
    targets: [
        .target(
            name: "phonedots_native",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "LiteRTLM", package: "litert-lm"),
            ] + ["Voz", "Who", "Ear", "Clear", "Uhm", "Redact", "Tongue", "Emo", "Gist", "Eye", "Moderator"].map {
                .product(name: $0, package: "desert-ant-core")
            }
        )
    ]
)
