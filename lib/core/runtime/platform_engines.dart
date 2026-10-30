import 'dart:async';

import 'package:flutter/services.dart';

import 'engine_types.dart';
import 'engines.dart';

/// Channel names shared with the Kotlin and Swift bridges. See
/// docs/NATIVE_BRIDGE.md for the full contract.
class Channels {
  static const llm = MethodChannel('phonedots/llm');
  static const llmEvents = EventChannel('phonedots/llm/events');
  static const specialist = MethodChannel('phonedots/specialist');
  static const specialistEvents = EventChannel('phonedots/specialist/events');
  static const device = MethodChannel('phonedots/device');
  static const intake = MethodChannel('phonedots/intake');
}

Map<String, dynamic> _map(Object? o) => o == null ? {} : Map<String, dynamic>.from(o as Map);

class PlatformLlmEngine implements LlmEngine {
  PlatformLlmEngine({required this.nativeTools});

  final bool nativeTools;
  final Set<String> _loaded = {};
  final Map<String, StreamController<GenEvent>> _requests = {};
  StreamSubscription<dynamic>? _events;
  int _nextRequest = 0;
  String? _activeRequest;

  @override
  bool get supportsNativeTools => nativeTools;

  @override
  bool get isDemo => false;

  void _ensureListening() {
    _events ??= Channels.llmEvents.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(dynamic raw) {
    final e = _map(raw);
    final controller = _requests[e['requestId']];
    if (controller == null) return;
    switch (e['type']) {
      case 'token':
        controller.add(TokenEvent(e['text'] as String));
      case 'thinking':
        controller.add(ThinkingEvent(e['text'] as String));
      case 'toolCalls':
        final calls = (e['calls'] as List).map((c) => ToolCallRequest.fromJson(_map(c))).toList();
        controller.add(ToolCallsEvent(calls));
      case 'done':
        controller.add(DoneEvent(GenerationStats.fromJson(_map(e['stats']))));
        _close(e['requestId'] as String);
      case 'error':
        controller.add(ErrorEvent(e['message'] as String? ?? 'Unknown error'));
        _close(e['requestId'] as String);
    }
  }

  void _close(String id) {
    _requests.remove(id)?.close();
    if (_activeRequest == id) _activeRequest = null;
  }

  @override
  Future<void> load({
    required String modelId,
    required String path,
    ComputeBackend backend = ComputeBackend.gpu,
    int maxTokens = 4096,
    bool vision = false,
    bool audio = false,
  }) async {
    await Channels.llm.invokeMethod('load', {
      'modelId': modelId,
      'path': path,
      'backend': backend.name,
      'maxTokens': maxTokens,
      'vision': vision,
      'audio': audio,
    });
    _loaded.add(modelId);
  }

  @override
  Future<void> unload(String modelId) async {
    await Channels.llm.invokeMethod('unload', {'modelId': modelId});
    _loaded.remove(modelId);
  }

  @override
  bool isLoaded(String modelId) => _loaded.contains(modelId);

  @override
  Stream<GenEvent> generate(GenerationRequest request) {
    _ensureListening();
    final id = 'r${_nextRequest++}';
    final controller = StreamController<GenEvent>();
    _requests[id] = controller;
    _activeRequest = id;
    Channels.llm.invokeMethod('generate', {'requestId': id, ...request.toJson()}).catchError((Object e) {
      controller.add(ErrorEvent(e is PlatformException ? (e.message ?? e.code) : '$e'));
      _close(id);
      return null;
    });
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    final id = _activeRequest;
    if (id == null) return;
    await Channels.llm.invokeMethod('cancel', {'requestId': id});
  }

  @override
  Future<void> resetSession(String sessionId) => Channels.llm.invokeMethod('resetSession', {'sessionId': sessionId});

  @override
  Future<DeviceProfile> deviceProfile() async =>
      DeviceProfile.fromJson(_map(await Channels.llm.invokeMethod('deviceProfile')));
}

class PlatformEmbedder implements Embedder {
  String? _modelId;

  @override
  bool get isDemo => false;

  @override
  int get dimensions => 256;

  @override
  bool get isReady => _modelId != null;

  @override
  Future<void> load({required String modelId, required String path}) async {
    await Channels.llm.invokeMethod('loadEmbedder', {'modelId': modelId, 'path': path, 'dimensions': dimensions});
    _modelId = modelId;
  }

  @override
  Future<List<double>> embed(String text) async {
    final v = await Channels.llm.invokeMethod<List<dynamic>>('embed', {'modelId': _modelId, 'text': text});
    return v!.map((e) => (e as num).toDouble()).toList();
  }
}

class PlatformSpecialistEngine implements SpecialistEngine {
  @override
  bool get isDemo => false;

  @override
  Future<Map<String, String>> availability() async =>
      Map<String, String>.from(await Channels.specialist.invokeMethod('availability') as Map);

  @override
  Future<bool> isDownloaded(String modelId) async =>
      await Channels.specialist.invokeMethod<bool>('isDownloaded', {'modelId': modelId}) ?? false;

  @override
  Stream<double> download(String modelId) {
    final controller = StreamController<double>();
    final sub = Channels.specialistEvents.receiveBroadcastStream().listen((raw) {
      final e = _map(raw);
      if (e['modelId'] == modelId) controller.add((e['progress'] as num).toDouble());
    });
    Channels.specialist
        .invokeMethod('download', {'modelId': modelId})
        .then(
          (_) {
            controller.add(1);
          },
          onError: (Object e) {
            controller.addError(e);
          },
        )
        .whenComplete(() {
          sub.cancel();
          controller.close();
        });
    return controller.stream;
  }

  @override
  Future<Map<String, dynamic>> run(String modelId, String task, Map<String, dynamic> input) async =>
      _map(await Channels.specialist.invokeMethod('run', {'modelId': modelId, 'task': task, 'input': input}));
}

class PlatformDeviceActions implements DeviceActions {
  @override
  bool get isDemo => false;

  @override
  Future<Map<String, dynamic>> invoke(String action, Map<String, dynamic> args) async =>
      _map(await Channels.device.invokeMethod('invoke', {'action': action, 'args': args}));
}
