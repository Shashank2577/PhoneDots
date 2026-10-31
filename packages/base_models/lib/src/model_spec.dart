/// How a model gets onto the device.
enum ModelSource {
  /// Plain files the store downloads itself (resume + SHA-256).
  file,

  /// A vendor SDK downloads its own weights; the store gives it a folder
  /// inside the shared store and records when it is ready.
  sdk,
}

/// One downloadable file of a model.
class ModelFile {
  const ModelFile(this.name, this.url, {this.sha256, this.bytes});

  /// Plain file name, stored at `<store>/<model id>/<name>`.
  final String name;
  final String url;

  /// Hex SHA-256. Null means the download is not verified (`./base check` warns).
  final String? sha256;
  final int? bytes;
}

/// A vendor SDK that manages its own weights.
class SdkRef {
  const SdkRef(this.name, this.version, this.key, {this.bundled = false});
  final String name;
  final String version;

  /// The SDK's own name for the model, e.g. "voz".
  final String key;

  /// Shipped inside the app with the SDK (Tongue): installing it fetches nothing.
  final bool bundled;
}

/// A model in the shared catalog (catalog/models.json).
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.family,
    required this.runtime,
    required this.role,
    required this.summary,
    required this.capabilities,
    required this.license,
    required this.platforms,
    required this.source,
    this.minRamMb = 0,
    this.recommended = false,
    this.approxBytes,
    this.sdk,
    this.files = const [],
  });

  final String id;
  final String name;
  final String family;

  /// Which engine runs it: litert-lm, desertant-sdk, onnx, ...
  final String runtime;

  /// planner, router, embedder, specialist, speech, ...
  final String role;
  final String summary;
  final Set<String> capabilities;
  final String license;

  /// Platforms where an engine for this model exists. The store can hold the
  /// files anywhere; this says where they can be run.
  final Set<String> platforms;
  final ModelSource source;
  final int minRamMb;
  final bool recommended;
  final int? approxBytes;
  final SdkRef? sdk;
  final List<ModelFile> files;

  /// Best-known size on disk.
  int get bytes {
    final known = files.fold<int>(0, (sum, f) => sum + (f.bytes ?? 0));
    return known > 0 ? known : (approxBytes ?? 0);
  }

  bool runsOn(String platform) => platforms.contains(platform);

  bool has(String capability) => capabilities.contains(capability);

  /// Whether a device with [totalRamMb] (0 = unknown) can comfortably run it.
  bool fits(int totalRamMb) => totalRamMb == 0 || minRamMb <= totalRamMb;
}
