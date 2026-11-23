#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import Foundation

/// Registers PhoneDots' channels: the LLM (LiteRT-LM), the Desert Ant
/// specialists and device actions. Shared by iOS and macOS.
public class PhoneDotsNativePlugin: NSObject, FlutterPlugin {
  private static var bridges: [AnyObject] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    bridges = [
      LlmBridge(messenger: messenger),
      SpecialistBridge(messenger: messenger),
      DeviceBridge(messenger: messenger),
    ]
    // Share intake is Android-only for now; answer Dart's handshake.
    FlutterMethodChannel(name: "phonedots/intake", binaryMessenger: messenger).setMethodCallHandler { _, result in result(nil) }
  }
}
