import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var bridges: [AnyObject] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhoneDotsBridges") else { return }
    let messenger = registrar.messenger()
    bridges = [
      LlmBridge(messenger: messenger),
      SpecialistBridge(messenger: messenger),
      DeviceBridge(messenger: messenger),
    ]
    // Share-extension intake is Android-only for now; answer Dart's handshake.
    FlutterMethodChannel(name: "phonedots/intake", binaryMessenger: messenger).setMethodCallHandler { _, result in result(nil) }
  }
}
