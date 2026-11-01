import Flutter
import UIKit

/// Shared model store on Apple platforms: every app of the vendor joins one
/// App Group (platform.yaml -> sharedModels.appleAppGroup) and keeps its
/// models in the group's container, so a model downloaded by one app is used
/// in place by all of them. Returns nil when the app lacks the entitlement;
/// the Dart side then falls back to a per-app folder and says so in settings.
public class BaseModelsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "base/models", binaryMessenger: registrar.messenger())
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
      let key = (call.arguments as? [String: Any])?["key"] as? String ?? "work"
      KeepAwake.begin(key)
      result(nil)
    case "keepAwakeUpdate":
      result(nil)
    case "keepAwakeEnd":
      let key = (call.arguments as? [String: Any])?["key"] as? String ?? "work"
      KeepAwake.end(key)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}


/// iOS can't keep an app running in the background for long: while a model
/// downloads or the AI writes an answer, the screen is kept from locking (so
/// the app stays in front), and if the user leaves anyway, iOS is asked for
/// the extra background time it allows (about 30 seconds).
enum KeepAwake {
  private static var tasks: [String: UIBackgroundTaskIdentifier] = [:]

  static func begin(_ key: String) {
    DispatchQueue.main.async {
      guard tasks[key] == nil else { return }
      tasks[key] = UIApplication.shared.beginBackgroundTask(withName: key) { end(key) }
      UIApplication.shared.isIdleTimerDisabled = true
    }
  }

  static func end(_ key: String) {
    DispatchQueue.main.async {
      guard let id = tasks.removeValue(forKey: key) else { return }
      if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
      if tasks.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
    }
  }
}
