import AVFoundation
import Contacts
import EventKit
#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import AppKit
import FlutterMacOS
#endif

/// Phone actions on iOS (and the ones a Mac has). Sending and calling open the
/// system composer; iOS does not let apps set timers, alarms or volume, so
/// those return a clear error. On a Mac there's no flashlight or battery API
/// to use, and sharing copies to the clipboard.
final class DeviceBridge: NSObject {
  private let events = EKEventStore()
  private let contacts = CNContactStore()

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "phonedots/device", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "invoke", let a = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      Task { @MainActor in
        let out = await self.invoke(a["action"] as? String ?? "", a["args"] as? [String: Any] ?? [:])
        result(out)
      }
    }
  }

  @MainActor
  private func open(_ url: String, _ done: String) async -> [String: Any] {
    #if os(iOS)
    guard let u = URL(string: url), await UIApplication.shared.open(u) else { return ["error": "No app on this phone can handle that."] }
    #else
    guard let u = URL(string: url), NSWorkspace.shared.open(u) else { return ["error": "No app on this Mac can handle that."] }
    #endif
    return ["ok": true, "message": done]
  }

  private func date(_ iso: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
      f.dateFormat = format
      if let d = f.date(from: String(iso.prefix(19))) { return d }
    }
    return nil
  }

  @MainActor
  private func invoke(_ action: String, _ a: [String: Any]) async -> [String: Any] {
    let s = { (k: String) in "\(a[k] ?? "")" }
    // Query values: escape the separators too, or "a & b" is cut at the "&".
    var valueAllowed = CharacterSet.urlQueryAllowed
    valueAllowed.remove(charactersIn: "&=+;?#")
    let enc = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? v }
    switch action {
    case "timer.set", "alarm.set":
      return ["error": "iOS does not let apps set timers or alarms. Ask Siri, or use the Clock app."]
    case "volume.set", "app.open":
      return ["error": "iOS does not allow this from apps."]
    case "calendar.create":
      do {
        guard try await events.requestWriteOnlyAccessToEvents() else { return ["error": "Calendar access was not allowed."] }
        guard let start = date(s("start")) else { return ["error": "Could not read the start date."] }
        let e = EKEvent(eventStore: events)
        e.title = s("title")
        e.startDate = start
        e.endDate = date(s("end")) ?? start.addingTimeInterval(3600)
        e.location = s("location")
        e.notes = s("notes")
        e.calendar = events.defaultCalendarForNewEvents
        try events.save(e, span: .thisEvent)
        return ["ok": true, "message": "Event added"]
      } catch {
        return ["error": "\(error.localizedDescription)"]
      }
    case "calendar.list":
      do {
        guard try await events.requestFullAccessToEvents() else { return ["error": "Calendar access was not allowed."] }
        let days = max(1, min(31, a["days"] as? Int ?? 1))
        let p = events.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(Double(days) * 86400), calendars: nil)
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let list = events.events(matching: p).prefix(30).map { ["title": $0.title ?? "", "start": f.string(from: $0.startDate), "location": $0.location ?? ""] }
        return ["events": Array(list), "summary": list.isEmpty ? "Nothing on your calendar." : "\(list.count) events."]
      } catch {
        return ["error": "\(error.localizedDescription)"]
      }
    case "contacts.search":
      do {
        guard try await contacts.requestAccess(for: .contacts) else { return ["error": "Contacts access was not allowed."] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let found = try contacts.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: s("name")), keysToFetch: keys)
        return ["contacts": found.prefix(10).map {
          ["name": "\($0.givenName) \($0.familyName)", "phones": $0.phoneNumbers.map { $0.value.stringValue }, "emails": $0.emailAddresses.map { "\($0.value)" }] as [String: Any]
        }]
      } catch {
        return ["error": "\(error.localizedDescription)"]
      }
    case "phone.dial": return await open("tel:\(enc(s("number")))", "Calling")
    case "sms.compose": return await open("sms:\(enc(s("to")))&body=\(enc(s("body")))", "Message drafted. Tap send.")
    case "email.compose": return await open("mailto:\(enc(s("to")))?subject=\(enc(s("subject")))&body=\(enc(s("body")))", "Email drafted")
    case "url.open": return await open(s("url"), "Opened")
    case "maps.navigate":
      let mode = ["walking": "w", "transit": "r", "cycling": "c"][s("mode")] ?? "d"
      return await open("maps://?daddr=\(enc(s("destination")))&dirflg=\(mode)", "Directions opened")
    #if os(iOS)
    case "settings.open": return await open(UIApplication.openSettingsURLString, "Settings opened")
    case "torch":
      guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return ["error": "No flashlight"] }
      let on = (a["on"] as? Bool) ?? (s("on") == "true")
      do {
        try device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        return ["ok": true, "on": on]
      } catch {
        return ["error": "\(error.localizedDescription)"]
      }
    case "battery":
      UIDevice.current.isBatteryMonitoringEnabled = true
      let state = UIDevice.current.batteryState
      return ["level": Int(UIDevice.current.batteryLevel * 100), "charging": state == .charging || state == .full]
    case "storage":
      let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
      let free = Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
      let total = Double(values?.volumeTotalCapacity ?? 0) / 1e9
      return ["free_gb": String(format: "%.1f", free), "total_gb": String(format: "%.1f", total), "summary": String(format: "%.1f GB free of %.0f GB.", free, total)]
    case "share.text":
      guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
        return ["error": "Nothing to present from"]
      }
      let vc = UIActivityViewController(activityItems: [s("text")], applicationActivities: nil)
      vc.popoverPresentationController?.sourceView = root.view
      root.present(vc, animated: true)
      return ["ok": true, "message": "Share sheet opened"]
    #else
    case "settings.open": return await open("x-apple.systempreferences:", "System Settings opened")
    case "torch", "battery":
      return ["error": "A Mac has no \(action == "torch" ? "flashlight" : "battery reading") PhoneDots can use."]
    case "storage":
      let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
      let free = Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
      let total = Double(values?.volumeTotalCapacity ?? 0) / 1e9
      return ["free_gb": String(format: "%.1f", free), "total_gb": String(format: "%.1f", total), "summary": String(format: "%.1f GB free of %.0f GB.", free, total)]
    case "share.text":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(s("text"), forType: .string)
      return ["ok": true, "message": "Copied to the clipboard"]
    #endif
    default:
      return ["error": "Unknown action \(action)"]
    }
  }
}
