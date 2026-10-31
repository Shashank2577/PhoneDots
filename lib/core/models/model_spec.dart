enum ModelProvider { gemma, desertAnt }

/// What the app uses the model for.
enum ModelRole { planner, router, embedder, specialist }

enum ModelCapability { text, image, audio, tools, thinking, embedding, speech, vision }

/// How a platform runs this model.
enum PlatformSupport { native, unsupported }

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.provider,
    required this.role,
    required this.summary,
    required this.capabilities,
    required this.approxBytes,
    required this.license,
    this.minRamMb = 0,
    this.hfRepo,
    this.fileName,
    this.sha256,
    this.android = PlatformSupport.native,
    this.ios = PlatformSupport.native,
    this.beta = false,
    this.recommended = false,
    this.gated = false,
  });

  final String id;
  final String name;
  final ModelProvider provider;
  final ModelRole role;
  final String summary;
  final Set<ModelCapability> capabilities;

  /// Exact for Gemma files, approximate for Desert Ant (the SDK downloads the
  /// variant for the device).
  final int approxBytes;
  final int minRamMb;
  final String license;

  /// Gemma files are downloaded by the app; Desert Ant models by their SDK.
  final String? hfRepo;
  final String? fileName;
  final String? sha256;

  final PlatformSupport android;
  final PlatformSupport ios;
  final bool beta;
  final bool recommended;

  /// Google's licence must be accepted on Hugging Face (signed in) before the
  /// file downloads; requests without an approved token get HTTP 401/403.
  final bool gated;

  String? get hfPage => hfRepo == null ? null : 'https://huggingface.co/$hfRepo';

  bool get appDownloads => hfRepo != null;

  String? get downloadUrl =>
      hfRepo == null ? null : 'https://huggingface.co/$hfRepo/resolve/main/$fileName?download=true';

  bool supports(String platform) => switch (platform) {
    'android' => android == PlatformSupport.native,
    'ios' => ios == PlatformSupport.native,
    _ => true,
  };

  bool has(ModelCapability c) => capabilities.contains(c);
}
