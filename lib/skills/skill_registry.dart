import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart';
import '../core/storage/json_store.dart';
import 'builtin/audio_skills.dart';
import 'builtin/knowledge_skills.dart';
import 'builtin/output_skills.dart';
import 'builtin/phone_skills.dart';
import 'builtin/text_skills.dart';
import 'builtin/vision_skills.dart';
import 'community/community_skill.dart';
import 'recipes/recipe.dart';
import 'skill.dart';

class SkillRegistry extends ChangeNotifier {
  SkillRegistry({required this.store, required this.settings, required this.platform});

  final JsonStore store;
  final AppSettings settings;
  final String platform;

  final List<Skill> builtIns = [
    ...audioSkills(),
    ...visionSkills(),
    ...textSkills(),
    ...phoneSkills(),
    ...knowledgeSkills(),
    ...outputSkills(),
  ];
  final List<Recipe> recipes = [];
  final List<CommunitySkill> community = [];

  static const _recipesKey = 'recipes';
  static const _communityKey = 'community-skills';

  Future<void> load() async {
    final saved = (await store.read(_recipesKey) as List?) ?? const [];
    recipes
      ..clear()
      ..addAll(builtInRecipes)
      ..addAll(saved.map((r) => Recipe.fromJson(Map<String, dynamic>.from(r as Map))));
    final c = (await store.read(_communityKey) as List?) ?? const [];
    community
      ..clear()
      ..addAll(c.map((m) => CommunitySkill.parse(Map<String, dynamic>.from(m as Map))));
    notifyListeners();
  }

  List<Skill> get all => [...builtIns, ...recipes.map(RecipeSkill.new), ...community];

  bool availableHere(Skill s) => s.platforms.isEmpty || s.platforms.contains(platform) || platform == 'demo';

  bool isEnabled(Skill s) => availableHere(s) && !settings.disabledSkills.contains(s.id);

  List<Skill> get enabled => all.where(isEnabled).toList();

  Skill? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> setEnabled(Skill s, bool on) =>
      settings.update((x) => on ? x.disabledSkills.remove(s.id) : x.disabledSkills.add(s.id));

  // Recipes

  Future<void> saveRecipe(Recipe r) async {
    recipes.removeWhere((x) => x.id == r.id);
    recipes.add(r);
    await _persistRecipes();
  }

  Future<void> deleteRecipe(Recipe r) async {
    recipes.removeWhere((x) => x.id == r.id);
    await _persistRecipes();
  }

  Future<void> _persistRecipes() async {
    notifyListeners();
    await store.write(_recipesKey, recipes.where((r) => !r.builtIn).map((r) => r.toJson()).toList());
  }

  // Community

  /// Fetches and validates a manifest without installing it.
  Future<CommunitySkill> fetchCommunity(String url) async {
    final uri = Uri.parse(url.trim());
    if (uri.scheme != 'https') throw const FormatException('Only https links are allowed');
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw FormatException('HTTP ${res.statusCode}');
    if (res.bodyBytes.length > 64 * 1024) throw const FormatException('Manifest is larger than 64 KB');
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    if (j is! Map) throw const FormatException('Manifest must be a JSON object');
    return CommunitySkill.parse(Map<String, dynamic>.from(j), sourceUrl: url);
  }

  Future<void> install(CommunitySkill s) async {
    community.removeWhere((x) => x.id == s.id);
    community.add(s);
    await _persistCommunity();
  }

  Future<void> uninstall(CommunitySkill s) async {
    community.removeWhere((x) => x.id == s.id);
    await _persistCommunity();
  }

  Future<void> _persistCommunity() async {
    notifyListeners();
    await store.write(_communityKey, community.map((c) => c.manifest).toList());
  }

  /// Picks the tools worth showing the model for this turn. Small models do
  /// better with a short, relevant tool list than with all sixty.
  List<Skill> selectFor(String text, {List<Attachment> attachments = const [], int max = 12}) {
    final words = text.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 2).toSet();
    final hasAudio = attachments.any((a) => a.kind == 'audio');
    final hasImage = attachments.any((a) => a.kind == 'image');
    const always = {'calculate', 'get_datetime', 'search_my_files', 'recall_memory', 'remember_fact'};

    double score(Skill s) {
      var v = 0.0;
      final hay = '${s.id.replaceAll('_', ' ')} ${s.name} ${s.description} ${s.examples.join(' ')}'.toLowerCase();
      for (final w in words) {
        if (hay.contains(w)) v += 1;
        if (w.length > 4 && hay.contains(w.substring(0, w.length - 1))) v += 0.5;
      }
      if (hasAudio && s.category == SkillCategory.audio) v += 3;
      if (hasImage && s.category == SkillCategory.vision) v += 3;
      if (!hasAudio && s.category == SkillCategory.audio) v -= 2;
      if (!hasImage && s.category == SkillCategory.vision) v -= 2;
      if (always.contains(s.id)) v += 1.5;
      return v;
    }

    final ranked = enabled.map((s) => (s, score(s))).where((e) => e.$2 > 0).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return ranked.take(max).map((e) => e.$1).toList();
  }
}
