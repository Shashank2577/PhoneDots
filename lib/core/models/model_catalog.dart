import 'model_spec.dart';

const _gemmaLicense = 'Gemma Terms of Use';
const _daLicense = 'Desert Ant: free up to 100k monthly active devices';

/// Files and checksums verified against huggingface.co/litert-community.
const gemmaModels = <ModelSpec>[
  ModelSpec(
    id: 'gemma-4-e2b',
    name: 'Gemma 4 E2B',
    provider: ModelProvider.gemma,
    role: ModelRole.planner,
    summary: 'Default brain. Chat, reasoning, tool use, image and audio input, thinking mode.',
    capabilities: {
      ModelCapability.text,
      ModelCapability.image,
      ModelCapability.audio,
      ModelCapability.tools,
      ModelCapability.thinking,
    },
    approxBytes: 2588147712,
    minRamMb: 6000,
    license: _gemmaLicense,
    hfRepo: 'litert-community/gemma-4-E2B-it-litert-lm',
    fileName: 'gemma-4-E2B-it.litertlm',
    sha256: '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    recommended: true,
  ),
  ModelSpec(
    id: 'gemma-4-e4b',
    name: 'Gemma 4 E4B',
    provider: ModelProvider.gemma,
    role: ModelRole.planner,
    summary: 'Smart mode for high-end phones. Stronger reasoning and longer tool chains.',
    capabilities: {
      ModelCapability.text,
      ModelCapability.image,
      ModelCapability.audio,
      ModelCapability.tools,
      ModelCapability.thinking,
    },
    approxBytes: 3659530240,
    minRamMb: 10000,
    license: _gemmaLicense,
    hfRepo: 'litert-community/gemma-4-E4B-it-litert-lm',
    fileName: 'gemma-4-E4B-it.litertlm',
    sha256: '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
  ),
  ModelSpec(
    id: 'functiongemma-270m-mobile-actions',
    name: 'FunctionGemma 270M',
    provider: ModelProvider.gemma,
    role: ModelRole.router,
    summary: 'Tiny always-on router. Turns phone commands into function calls in a fraction of a second.',
    capabilities: {ModelCapability.text, ModelCapability.tools},
    approxBytes: 288964608,
    minRamMb: 2000,
    license: _gemmaLicense,
    hfRepo: 'litert-community/functiongemma-270m-ft-mobile-actions',
    fileName: 'mobile_actions_q8_ekv1024.litertlm',
    sha256: '33e295cbd996b419bb1de8f3f85c5b6b01ee058a2c89bdb2173cf3e6ff4ce9d0',
    recommended: true,
  ),
  ModelSpec(
    id: 'gemma-3-270m',
    name: 'Gemma 3 270M',
    provider: ModelProvider.gemma,
    role: ModelRole.planner,
    summary: 'Smallest Gemma. Fast drafts and simple rewrites on low-memory phones.',
    capabilities: {ModelCapability.text},
    approxBytes: 304005120,
    minRamMb: 2000,
    license: _gemmaLicense,
    hfRepo: 'litert-community/gemma-3-270m-it',
    fileName: 'gemma3-270m-it-q8.litertlm',
    sha256: '757e9119fa5bd667a2774fb470ac4afcd3190a21c677f8e69a5d6bc908abdd63',
  ),
  ModelSpec(
    id: 'embeddinggemma-2-text-270m',
    name: 'EmbeddingGemma 2 · Text',
    provider: ModelProvider.gemma,
    role: ModelRole.embedder,
    summary: 'Semantic search over your files, notes and memory.',
    capabilities: {ModelCapability.embedding},
    approxBytes: 164626432,
    minRamMb: 2000,
    license: _gemmaLicense,
    hfRepo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    fileName: 'embeddinggemma-2-text-270m.litertlm',
    sha256: '2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb',
    recommended: true,
  ),
  ModelSpec(
    id: 'embeddinggemma-2-text-vision-440m',
    name: 'EmbeddingGemma 2 · Text + Vision',
    provider: ModelProvider.gemma,
    role: ModelRole.embedder,
    summary: 'Search photos and text in one index ("dog on the beach").',
    capabilities: {ModelCapability.embedding, ModelCapability.image},
    approxBytes: 387710976,
    minRamMb: 4000,
    license: _gemmaLicense,
    hfRepo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    fileName: 'embeddinggemma-2-text-vision-440m.litertlm',
    sha256: '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0',
  ),
];

ModelSpec _da(
  String key,
  String name,
  String summary,
  Set<ModelCapability> caps,
  int mb, {
  bool android = true,
  bool beta = false,
}) => ModelSpec(
  id: 'desertant.$key',
  name: name,
  provider: ModelProvider.desertAnt,
  role: ModelRole.specialist,
  summary: summary,
  capabilities: caps,
  approxBytes: mb * 1000 * 1000,
  license: _daLicense,
  android: android ? PlatformSupport.native : PlatformSupport.unsupported,
  beta: beta,
);

/// Platforms per desert-ant-core 4.2.1. Sizes are approximate per-device
/// downloads, fetched by the Desert Ant SDK on first use.
final desertAntModels = <ModelSpec>[
  _da('voz', 'Voz', 'Speech recognition, 25 languages, word timestamps.', {ModelCapability.speech}, 470),
  _da('who', 'Who', 'Speaker labels: who spoke when.', {ModelCapability.speech}, 130),
  _da('ear', 'Ear', 'Spoken language identification, 102 languages.', {ModelCapability.speech}, 10),
  _da('clear', 'Clear', 'Speech enhancement: denoise, dereverb, loudness.', {ModelCapability.audio}, 150),
  _da('uhm', 'Uhm', 'Filler-word detection ("uh", "um").', {ModelCapability.speech}, 165, android: false),
  _da('align', 'Align', 'Word-timestamp refinement for transcripts.', {ModelCapability.speech}, 1, android: false),
  _da('redact', 'Redact', 'PII detection and redaction, multilingual.', {ModelCapability.text}, 24),
  _da('tongue', 'Tongue', 'Language identification from a few words.', {ModelCapability.text}, 2),
  _da('emo', 'Emo', 'Emoji suggestions.', {ModelCapability.text}, 10),
  _da('gist', 'Gist', 'Topic tagging across 36 topics.', {ModelCapability.text}, 26),
  _da('title', 'Title', 'Titles and short descriptions for any text.', {ModelCapability.text}, 290, android: false),
  _da('eye', 'Eye', 'Photo understanding: scenes, quality, faces, best crop.', {ModelCapability.vision}, 66),
  _da('moderator', 'Moderator', 'NSFW image detection.', {ModelCapability.vision}, 9),
  _da('shapes', 'Shapes', 'Turns rough strokes into clean shapes.', {ModelCapability.vision}, 1),
  _da('clips', 'Clips', 'Best moments of talking video for shorts.', {ModelCapability.speech}, 560, android: false),
];

final allModels = <ModelSpec>[...gemmaModels, ...desertAntModels];

ModelSpec? modelById(String id) {
  for (final m in allModels) {
    if (m.id == id) return m;
  }
  return null;
}
