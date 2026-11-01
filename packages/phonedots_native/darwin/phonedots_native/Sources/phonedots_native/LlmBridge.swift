#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import Foundation

#if canImport(LiteRTLM)
import LiteRTLM
#endif

/// Gemma on LiteRT-LM (Swift API). Same channel contract as the Android
/// bridge (docs/NATIVE_BRIDGE.md). The Swift API only supports compile-time
/// tools, so tools are described in the system prompt by Dart and calls are
/// parsed from text there.
final class LlmBridge: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  #if canImport(LiteRTLM)
  private final class Session {
    let conversation: Conversation
    let modelId: String
    let key: String
    var synced: Int
    init(conversation: Conversation, modelId: String, key: String, synced: Int) {
      self.conversation = conversation
      self.modelId = modelId
      self.key = key
      self.synced = synced
    }
  }

  private var engines: [String: Engine] = [:]
  private var sessions: [String: Session] = [:]
  private var active: [String: Conversation] = [:]
  private var embedder: EmbeddingEngine?
  private var embedDims = 256
  private let lock = NSLock()
  #endif

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "phonedots/llm", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    FlutterEventChannel(name: "phonedots/llm/events", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ event: [String: Any?]) {
    DispatchQueue.main.async { self.sink?(event.compactMapValues { $0 }) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "deviceProfile" {
      result([
        "platform": Self.platformName,
        "totalRamMb": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
        "model": Self.machine(),
        "gpu": true,
        "npu": true,
      ])
      return
    }
    #if canImport(LiteRTLM)
    Task.detached { [weak self] in
      guard let self else { return }
      do {
        switch call.method {
        case "load": try await self.load(args); self.reply(result, nil)
        case "unload":
          let id = args["modelId"] as? String ?? ""
          self.lock.withLock {
            self.sessions = self.sessions.filter { $0.value.modelId != id }
            self.engines[id] = nil
          }
          self.reply(result, nil)
        case "generate":
          self.reply(result, nil)
          await self.generate(args)
        case "cancel":
          let c = self.lock.withLock { self.active[args["requestId"] as? String ?? ""] }
          try? c?.cancel()
          self.reply(result, nil)
        case "resetSession":
          _ = self.lock.withLock { self.sessions.removeValue(forKey: args["sessionId"] as? String ?? "") }
          self.reply(result, nil)
        case "loadEmbedder":
          self.embedDims = args["dimensions"] as? Int ?? 256
          let e = EmbeddingEngine(config: EmbeddingEngineConfig(modelPath: args["path"] as! String, backend: .cpu()))
          try await e.initialize()
          self.embedder = e
          self.reply(result, nil)
        case "embed":
          guard let e = self.embedder else { throw NSError(domain: "llm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Embedder not loaded"]) }
          let r = try await e.computeEmbedding(contents: [.text(args["text"] as? String ?? "")], options: EmbeddingOptions(normalize: true, outputSize: self.embedDims))
          self.reply(result, r.embedding.map { Double($0) })
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "llm", message: "\(error)", details: nil)) }
      }
    }
    #else
    result(FlutterError(code: "unavailable", message: "Add the LiteRTLM Swift package to the Runner target (docs/IOS_SETUP.md).", details: nil))
    #endif
  }

  #if os(macOS)
  private static let platformName = "macos"
  #else
  private static let platformName = "ios"
  #endif

  private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  #if canImport(LiteRTLM)
  // Engine and EmbeddingEngine are actors in LiteRT-LM's Swift API: every call is awaited.
  private func load(_ a: [String: Any]) async throws {
    let id = a["modelId"] as! String
    let make: (Bool) async throws -> Engine = { gpu in
      let config = try EngineConfig(
        modelPath: a["path"] as! String,
        backend: gpu ? .gpu : .cpu(),
        visionBackend: (a["vision"] as? Bool ?? false) ? .gpu : nil,
        audioBackend: (a["audio"] as? Bool ?? false) ? .cpu() : nil,
        maxNumTokens: a["maxTokens"] as? Int ?? 4096,
        cacheDir: NSTemporaryDirectory()
      )
      let engine = Engine(engineConfig: config)
      try await engine.initialize()
      return engine
    }
    let wantsGpu = (a["backend"] as? String) == "gpu"
    let engine: Engine
    do {
      engine = try await make(wantsGpu)
    } catch where wantsGpu {
      engine = try await make(false)
    }
    lock.withLock { engines[id] = engine }
  }

  private func message(_ t: [String: Any]) -> Message {
    let text = t["text"] as? String ?? ""
    switch t["role"] as? String {
    case "model":
      let calls = (t["toolCalls"] as? [[String: Any]] ?? []).map {
        ToolCall(name: $0["name"] as? String ?? "", id: $0["id"] as? String ?? "", arguments: $0["arguments"] as? [String: Any] ?? [:])
      }
      // Dart parses calls from text on iOS, so the model's own text is the faithful replay.
      return Message(contents: [.text(text.isEmpty && !calls.isEmpty ? "(tool call)" : text)], role: .model)
    case "tool":
      let parts: [Content] = (t["toolResponses"] as? [[String: Any]] ?? []).map {
        .toolResponse(name: $0["name"] as? String ?? "", response: $0["response"] ?? [:], id: $0["id"] as? String ?? "")
      }
      return Message(contents: parts.isEmpty ? [.text("{}")] : parts, role: .tool)
    default:
      var parts: [Content] = []
      for p in t["images"] as? [String] ?? [] { parts.append(.imageFile(p)) }
      for p in t["audio"] as? [String] ?? [] { parts.append(.audioFile(p)) }
      if !text.isEmpty || parts.isEmpty { parts.append(.text(text)) }
      return Message(contents: parts, role: .user)
    }
  }

  private func generate(_ a: [String: Any]) async {
    let requestId = a["requestId"] as? String ?? ""
    let started = Date()
    var firstToken: Date?
    var chunks = 0
    do {
      let modelId = a["modelId"] as? String ?? ""
      let sessionId = a["sessionId"] as? String ?? ""
      let history = a["history"] as? [[String: Any]] ?? []
      let system = a["systemPrompt"] as? String ?? ""
      let sampler = a["sampler"] as? [String: Any] ?? [:]
      guard let engine = lock.withLock({ engines[modelId] }), let last = history.last else {
        throw NSError(domain: "llm", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model \(modelId) is not loaded"])
      }
      let key = "\(modelId)|\(system.hashValue)"
      var session = lock.withLock { sessions[sessionId] }
      if session == nil || session!.key != key || session!.synced != history.count - 1 {
        let config = ConversationConfig(
          systemMessage: system.isEmpty ? nil : Message(system, role: .system),
          initialMessages: history.dropLast().map(message),
          samplerConfig: try SamplerConfig(
            topK: sampler["topK"] as? Int ?? 40,
            topP: Float(sampler["topP"] as? Double ?? 0.95),
            temperature: Float(sampler["temperature"] as? Double ?? 0.7)
          ),
          automaticToolCalling: false
        )
        let s = Session(conversation: try await engine.createConversation(with: config), modelId: modelId, key: key, synced: history.count - 1)
        lock.withLock { sessions[sessionId] = s }
        session = s
      }
      let conversation = session!.conversation
      lock.withLock { active[requestId] = conversation }
      let thinking = a["thinking"] as? Bool ?? false
      for try await chunk in conversation.sendMessageStream(
        message(last),
        extraContext: ["enable_thinking": thinking],
        maxOutputTokens: sampler["maxTokens"] as? Int
      ) {
        if firstToken == nil { firstToken = Date() }
        if let thought = chunk.channels["thought"], !thought.isEmpty {
          emit(["requestId": requestId, "type": "thinking", "text": thought])
        }
        let text = chunk.toString
        if !text.isEmpty {
          chunks += 1
          emit(["requestId": requestId, "type": "token", "text": text])
        }
      }
      session!.synced = history.count + 1
      lock.withLock { active[requestId] = nil }
      var stats: [String: Any] = [
        "ttftMs": Int((firstToken ?? started).timeIntervalSince(started) * 1000),
        "totalMs": Int(Date().timeIntervalSince(started) * 1000),
        "outputTokens": chunks,
      ]
      if let b = try? conversation.getBenchmarkInfo() {
        stats["outputTokens"] = b.lastDecodeTokenCount
        stats["prefillTps"] = b.lastPrefillTokensPerSecond
        stats["decodeTps"] = b.lastDecodeTokensPerSecond
      }
      emit(["requestId": requestId, "type": "done", "stats": stats])
    } catch {
      lock.withLock {
        active[requestId] = nil
        sessions[a["sessionId"] as? String ?? ""] = nil
      }
      emit(["requestId": requestId, "type": "error", "message": "\(error)"])
    }
  }
  #endif

  private static func machine() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }
}
