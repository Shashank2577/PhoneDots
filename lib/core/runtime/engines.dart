import 'engine_types.dart';

/// Gemma-family inference (LiteRT-LM on device).
abstract class LlmEngine {
  /// Whether the runtime does constrained tool calling itself (LiteRT-LM
  /// tool use). When false, tools are described in the prompt and calls are
  /// parsed from text by the agent.
  bool get supportsNativeTools;

  bool get isDemo;

  Future<void> load({
    required String modelId,
    required String path,
    ComputeBackend backend = ComputeBackend.gpu,
    int maxTokens = 4096,
    bool vision = false,
    bool audio = false,
  });

  Future<void> unload(String modelId);

  bool isLoaded(String modelId);

  Stream<GenEvent> generate(GenerationRequest request);

  Future<void> cancel();

  /// Drops the cached native conversation for [sessionId].
  Future<void> resetSession(String sessionId);

  Future<DeviceProfile> deviceProfile();
}

/// EmbeddingGemma via LiteRT-LM's embedding engine.
abstract class Embedder {
  bool get isDemo;

  /// Matryoshka-truncated dimension used by the index.
  int get dimensions;

  Future<void> load({required String modelId, required String path});

  bool get isReady;

  Future<List<double>> embed(String text);
}

/// Desert Ant specialist models. Each call names a model and a task and
/// returns plain JSON so skills stay platform-agnostic.
abstract class SpecialistEngine {
  bool get isDemo;

  /// Returns per-model availability: "native", "unsupported".
  Future<Map<String, String>> availability();

  Future<bool> isDownloaded(String modelId);

  /// Emits download progress 0..1, completes when ready.
  Stream<double> download(String modelId);

  Future<Map<String, dynamic>> run(String modelId, String task, Map<String, dynamic> input);
}

/// OS integrations (calendar, contacts, intents, torch...).
abstract class DeviceActions {
  bool get isDemo;

  Future<Map<String, dynamic>> invoke(String action, Map<String, dynamic> args);
}
