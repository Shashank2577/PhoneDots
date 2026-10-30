/// Shared value types for the on-device engines (LLM, specialists, embedder).
library;

enum ComputeBackend { cpu, gpu, npu }

enum TurnRole { system, user, model, tool }

/// A tool the model may call. [parameters] is an OpenAPI/JSON-schema object.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'parameters': parameters,
      };
}

class ToolCallRequest {
  const ToolCallRequest({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'arguments': arguments};

  factory ToolCallRequest.fromJson(Map<String, dynamic> j) => ToolCallRequest(
        id: (j['id'] ?? '') as String,
        name: j['name'] as String,
        arguments: Map<String, dynamic>.from((j['arguments'] ?? const {}) as Map),
      );
}

class ToolResponse {
  const ToolResponse({required this.callId, required this.name, required this.response});

  final String callId;
  final String name;
  final Map<String, dynamic> response;

  Map<String, dynamic> toJson() => {'id': callId, 'name': name, 'response': response};

  factory ToolResponse.fromJson(Map<String, dynamic> j) => ToolResponse(
        callId: (j['id'] ?? '') as String,
        name: j['name'] as String,
        response: Map<String, dynamic>.from(j['response'] as Map),
      );
}

/// One message in the engine-facing history. Paths point at local files.
class EngineTurn {
  const EngineTurn({
    required this.role,
    this.text = '',
    this.imagePaths = const [],
    this.audioPaths = const [],
    this.toolCalls = const [],
    this.toolResponses = const [],
  });

  final TurnRole role;
  final String text;
  final List<String> imagePaths;
  final List<String> audioPaths;
  final List<ToolCallRequest> toolCalls;
  final List<ToolResponse> toolResponses;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'text': text,
        'images': imagePaths,
        'audio': audioPaths,
        'toolCalls': toolCalls.map((c) => c.toJson()).toList(),
        'toolResponses': toolResponses.map((r) => r.toJson()).toList(),
      };

  factory EngineTurn.fromJson(Map<String, dynamic> j) => EngineTurn(
        role: TurnRole.values.byName(j['role'] as String),
        text: j['text'] as String? ?? '',
        imagePaths: (j['images'] as List? ?? const []).cast<String>(),
        audioPaths: (j['audio'] as List? ?? const []).cast<String>(),
        toolCalls: (j['toolCalls'] as List? ?? const [])
            .map((c) => ToolCallRequest.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList(),
        toolResponses: (j['toolResponses'] as List? ?? const [])
            .map((r) => ToolResponse.fromJson(Map<String, dynamic>.from(r as Map)))
            .toList(),
      );
}

class SamplerSettings {
  const SamplerSettings({this.temperature = 0.7, this.topK = 40, this.topP = 0.95, this.maxTokens = 1024});

  final double temperature;
  final int topK;
  final double topP;
  final int maxTokens;

  Map<String, dynamic> toJson() =>
      {'temperature': temperature, 'topK': topK, 'topP': topP, 'maxTokens': maxTokens};
}

class GenerationRequest {
  const GenerationRequest({
    required this.modelId,
    required this.sessionId,
    required this.history,
    this.systemPrompt = '',
    this.tools = const [],
    this.thinking = false,
    this.sampler = const SamplerSettings(),
  });

  final String modelId;

  /// Native engines keep a live conversation per session so only the new
  /// turn is prefilled. A changed history resets it.
  final String sessionId;
  final List<EngineTurn> history;
  final String systemPrompt;
  final List<ToolSpec> tools;
  final bool thinking;
  final SamplerSettings sampler;

  Map<String, dynamic> toJson() => {
        'modelId': modelId,
        'sessionId': sessionId,
        'history': history.map((t) => t.toJson()).toList(),
        'systemPrompt': systemPrompt,
        'tools': tools.map((t) => t.toJson()).toList(),
        'thinking': thinking,
        'sampler': sampler.toJson(),
      };
}

class GenerationStats {
  const GenerationStats({
    this.timeToFirstTokenMs = 0,
    this.totalMs = 0,
    this.outputTokens = 0,
    this.prefillTokensPerSec,
    this.decodeTokensPerSec,
  });

  final int timeToFirstTokenMs;
  final int totalMs;
  final int outputTokens;
  final double? prefillTokensPerSec;
  final double? decodeTokensPerSec;

  double get effectiveTokensPerSec {
    if (decodeTokensPerSec != null) return decodeTokensPerSec!;
    final decodeMs = totalMs - timeToFirstTokenMs;
    if (decodeMs <= 0 || outputTokens == 0) return 0;
    return outputTokens / (decodeMs / 1000);
  }

  factory GenerationStats.fromJson(Map<String, dynamic> j) => GenerationStats(
        timeToFirstTokenMs: (j['ttftMs'] as num?)?.toInt() ?? 0,
        totalMs: (j['totalMs'] as num?)?.toInt() ?? 0,
        outputTokens: (j['outputTokens'] as num?)?.toInt() ?? 0,
        prefillTokensPerSec: (j['prefillTps'] as num?)?.toDouble(),
        decodeTokensPerSec: (j['decodeTps'] as num?)?.toDouble(),
      );
}

sealed class GenEvent {
  const GenEvent();
}

class TokenEvent extends GenEvent {
  const TokenEvent(this.text);
  final String text;
}

class ThinkingEvent extends GenEvent {
  const ThinkingEvent(this.text);
  final String text;
}

class ToolCallsEvent extends GenEvent {
  const ToolCallsEvent(this.calls);
  final List<ToolCallRequest> calls;
}

class DoneEvent extends GenEvent {
  const DoneEvent(this.stats);
  final GenerationStats stats;
}

class ErrorEvent extends GenEvent {
  const ErrorEvent(this.message);
  final String message;
}

class DeviceProfile {
  const DeviceProfile({
    required this.platform,
    required this.totalRamMb,
    this.model = '',
    this.socName = '',
    this.supportsGpu = true,
    this.supportsNpu = false,
    this.isNative = true,
  });

  final String platform;
  final int totalRamMb;
  final String model;
  final String socName;
  final bool supportsGpu;
  final bool supportsNpu;

  /// False when running on the demo engine (web, desktop, tests).
  final bool isNative;

  factory DeviceProfile.fromJson(Map<String, dynamic> j) => DeviceProfile(
        platform: j['platform'] as String? ?? 'unknown',
        totalRamMb: (j['totalRamMb'] as num?)?.toInt() ?? 0,
        model: j['model'] as String? ?? '',
        socName: j['soc'] as String? ?? '',
        supportsGpu: j['gpu'] as bool? ?? true,
        supportsNpu: j['npu'] as bool? ?? false,
      );
}
