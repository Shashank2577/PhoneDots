import Flutter
import Foundation

#if canImport(Voz)
import Voz
#endif
#if canImport(Who)
import Who
#endif
#if canImport(Ear)
import Ear
#endif
#if canImport(Clear)
import Clear
#endif
#if canImport(Uhm)
import Uhm
#endif
#if canImport(Redact)
import Redact
#endif
#if canImport(Tongue)
import Tongue
#endif
#if canImport(Emo)
import Emo
#endif
#if canImport(Gist)
import Gist
#endif
#if canImport(Eye)
import Eye
#endif
#if canImport(Moderator)
import Moderator
#endif

/// Desert Ant specialists on Core ML (desert-ant-core Swift package). Each
/// product is optional: add the ones you ship in Xcode (docs/IOS_SETUP.md).
final class SpecialistBridge: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "phonedots/specialist", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    FlutterEventChannel(name: "phonedots/specialist/events", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private static var available: [String] {
    var ids: [String] = []
    #if canImport(Voz)
    ids.append("voz")
    #endif
    #if canImport(Who)
    ids.append("who")
    #endif
    #if canImport(Ear)
    ids.append("ear")
    #endif
    #if canImport(Clear)
    ids.append("clear")
    #endif
    #if canImport(Uhm)
    ids.append("uhm")
    #endif
    #if canImport(Redact)
    ids.append("redact")
    #endif
    #if canImport(Tongue)
    ids.append("tongue")
    #endif
    #if canImport(Emo)
    ids.append("emo")
    #endif
    #if canImport(Gist)
    ids.append("gist")
    #endif
    #if canImport(Eye)
    ids.append("eye")
    #endif
    #if canImport(Moderator)
    ids.append("moderator")
    #endif
    return ids
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let key = (args["modelId"] as? String ?? "").replacingOccurrences(of: "desertant.", with: "")
    switch call.method {
    case "availability":
      var map: [String: String] = [:]
      for k in ["voz", "who", "ear", "clear", "uhm", "redact", "tongue", "emo", "gist", "eye", "moderator", "align", "title", "clips", "shapes"] {
        map["desertant.\(k)"] = Self.available.contains(k) ? "native" : "unsupported"
      }
      result(map)
    case "isDownloaded":
      Task { let ok = await self.isDownloaded(key); DispatchQueue.main.async { result(ok) } }
    case "download":
      Task {
        do {
          try await self.download(key) { p in
            DispatchQueue.main.async { self.sink?(["modelId": "desertant.\(key)", "progress": p]) }
          }
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "download", message: "\(error)", details: nil)) }
        }
      }
    case "run":
      Task {
        let out: [String: Any]
        do {
          out = try await self.run(key, args["input"] as? [String: Any] ?? [:])
        } catch {
          out = ["error": "\(error)"]
        }
        DispatchQueue.main.async { result(out) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func unsupported(_ key: String) -> NSError {
    NSError(domain: "specialist", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(key.capitalized) is not included in this build. Add it in Xcode (docs/IOS_SETUP.md)."])
  }

  private func isDownloaded(_ key: String) async -> Bool {
    switch key {
    #if canImport(Voz)
    case "voz": return Voz.isDownloaded()
    #endif
    #if canImport(Who)
    case "who": return Who().isDownloaded()
    #endif
    #if canImport(Ear)
    case "ear": return Ear.isDownloaded()
    #endif
    #if canImport(Redact)
    case "redact": return Redact().isDownloaded()
    #endif
    #if canImport(Emo)
    case "emo": return Emo().isDownloaded()
    #endif
    #if canImport(Gist)
    case "gist": return Gist().isDownloaded()
    #endif
    #if canImport(Eye)
    case "eye": return Eye().isDownloaded()
    #endif
    #if canImport(Tongue)
    case "tongue": return true
    #endif
    default: return false
    }
  }

  private func download(_ key: String, progress: @escaping @Sendable (Double) -> Void) async throws {
    switch key {
    #if canImport(Voz)
    case "voz": try await Voz.download { progress($0.fraction) }
    #endif
    #if canImport(Who)
    case "who": try await Who().download(progress: progress)
    #endif
    #if canImport(Ear)
    case "ear": try await Ear().download(progress: progress)
    #endif
    #if canImport(Redact)
    case "redact": try await Redact().download(progress: progress)
    #endif
    #if canImport(Emo)
    case "emo": try await Emo().download(progress: progress)
    #endif
    #if canImport(Gist)
    case "gist": try await Gist().download(progress: progress)
    #endif
    #if canImport(Eye)
    case "eye": try await Eye().download(progress: progress)
    #endif
    #if canImport(Tongue)
    case "tongue": return
    #endif
    default:
      // Models without an explicit download fetch on first use.
      return
    }
  }

  private func run(_ key: String, _ input: [String: Any]) async throws -> [String: Any] {
    let audio = URL(fileURLWithPath: input["audioPath"] as? String ?? "")
    let image = URL(fileURLWithPath: input["imagePath"] as? String ?? "")
    let text = input["text"] as? String ?? ""
    switch key {
    #if canImport(Voz)
    case "voz":
      let r = try await Voz().transcribe(audio)
      return ["text": r.text, "duration": r.duration, "words": r.words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }]
    #endif
    #if canImport(Who)
    case "who":
      let r = try await Who().diarize(contentsOf: audio)
      return ["speakerCount": r.speakerCount, "turns": r.turns.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end] as [String: Any] }]
    #endif
    #if canImport(Ear)
    case "ear":
      let r = try await Ear().identify(contentsOf: audio)
      return ["language": r.language ?? "", "confidence": r.confidence, "isReliable": r.isReliable]
    #endif
    #if canImport(Clear)
    case "clear":
      let out = audio.deletingPathExtension().path + "-clear.wav"
      let r = try await Clear().enhance(path: audio.path, to: out)
      return ["outputPath": out, "measuredLufs": r.measuredLUFS ?? 0]
    #endif
    #if canImport(Uhm)
    case "uhm":
      let r = try await Uhm().analyze(audioPath: audio.path)
      return ["fillers": r.fillers.map { ["start": $0.start, "end": $0.end, "confidence": $0.confidence, "type": "\($0.type)"] as [String: Any] }]
    #endif
    #if canImport(Redact)
    case "redact":
      let r = try await Redact().redaction(of: text)
      return [
        "redactedText": r.redactedText,
        "items": r.items.map { ["label": $0.label.displayName, "original": $0.original, "placeholder": $0.placeholder, "confidence": $0.confidence] as [String: Any] },
      ]
    #endif
    #if canImport(Tongue)
    case "tongue":
      let d = try Tongue().detect(text)
      return ["language": d.language ?? "", "confidence": d.candidates.first?.probability ?? 0, "isTooCloseToCall": d.isTooCloseToCall]
    #endif
    #if canImport(Emo)
    case "emo":
      let r = try await Emo().suggestions(for: text, limit: input["limit"] as? Int ?? 3)
      return ["suggestions": r.map { ["emoji": $0.emoji, "confidence": $0.confidence] as [String: Any] }]
    #endif
    #if canImport(Gist)
    case "gist":
      let r = try await Gist().classify(text)
      return ["topics": r.map { ["slug": $0.slug, "name": $0.name, "score": $0.score] as [String: Any] }]
    #endif
    #if canImport(Eye)
    case "eye":
      let a = try await Eye().analyze(contentsOf: image)
      return [
        "kind": a.kind.map { "\($0)" } ?? "",
        "tags": a.tags().map { "\($0)" },
        "aesthetic": a.scores?.aesthetic ?? 0,
        "keeper": a.scores?.keeper ?? 0,
        "faces": a.faces?.count ?? 0,
      ]
    #endif
    #if canImport(Moderator)
    case "moderator":
      let r = try await Moderator().analyze(contentsOf: image)
      return ["isNSFW": r.isNSFW, "score": r.score]
    #endif
    default:
      throw unsupported(key)
    }
  }
}
