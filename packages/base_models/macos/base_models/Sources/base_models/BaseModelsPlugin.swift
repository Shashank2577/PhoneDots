import FlutterMacOS
import Foundation

/// Shared model store on Apple platforms: every app of the vendor joins one
/// App Group (platform.yaml -> sharedModels.appleAppGroup) and keeps its
/// models in the group's container, so a model downloaded by one app is used
/// in place by all of them. Returns nil when the app lacks the entitlement;
/// the Dart side then falls back to a per-app folder and says so in settings.
public class BaseModelsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "base/models", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(BaseModelsPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "appGroupDir":
      guard let args = call.arguments as? [String: Any], let group = args["group"] as? String,
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
      else {
        result(nil)
        return
      }
      do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Models are large and re-downloadable: keep them out of iCloud/Time Machine backups.
        var dir = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        result(url.path)
      } catch {
        result(nil)
      }
    case "keepAwakeBegin":
      let args = call.arguments as? [String: Any]
      KeepAwake.begin(args?["key"] as? String ?? "work", args?["text"] as? String ?? "working")
      result(nil)
    case "keepAwakeUpdate":
      result(nil)
    case "keepAwakeEnd":
      KeepAwake.end((call.arguments as? [String: Any])?["key"] as? String ?? "work")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}


/// While a model downloads or the AI writes an answer, the Mac neither sleeps
/// nor slows the app down (App Nap).
enum KeepAwake {
  private static var activities: [String: NSObjectProtocol] = [:]
  private static let lock = NSLock()

  static func begin(_ key: String, _ text: String) {
    lock.lock(); defer { lock.unlock() }
    guard activities[key] == nil else { return }
    activities[key] = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: text)
  }

  static func end(_ key: String) {
    lock.lock(); defer { lock.unlock() }
    if let a = activities.removeValue(forKey: key) { ProcessInfo.processInfo.endActivity(a) }
  }
}
