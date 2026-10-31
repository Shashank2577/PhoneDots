import 'package:flutter/material.dart';

import 'storage/json_store.dart';

class AppSettings extends ChangeNotifier {
  AppSettings(this._store);

  final JsonStore _store;
  static const _key = 'settings';

  ThemeMode themeMode = ThemeMode.system;

  /// Body font voice (see Voice in theme.dart): formal, friendly, neat, loose, handwritten.
  String voice = 'neat';
  String hfToken = '';
  String plannerId = 'gemma-4-e2b';
  String routerId = 'functiongemma-270m-mobile-actions';
  String embedderId = 'embeddinggemma-2-text-270m';
  bool thinking = false;
  bool useRouter = true;
  bool useGpu = true;
  int maxSteps = 6;
  double temperature = 0.7;
  bool onboarded = false;
  Set<String> disabledSkills = {};

  /// Skills with a first-time confirmation the user already granted.
  Set<String> grantedSkills = {};

  Future<void> load() async {
    final j = await _store.read(_key) as Map?;
    if (j == null) return;
    themeMode = ThemeMode.values.byName(j['themeMode'] as String? ?? 'system');
    voice = j['voice'] as String? ?? voice;
    hfToken = j['hfToken'] as String? ?? '';
    plannerId = j['plannerId'] as String? ?? plannerId;
    routerId = j['routerId'] as String? ?? routerId;
    embedderId = j['embedderId'] as String? ?? embedderId;
    thinking = j['thinking'] as bool? ?? thinking;
    useRouter = j['useRouter'] as bool? ?? useRouter;
    useGpu = j['useGpu'] as bool? ?? useGpu;
    maxSteps = j['maxSteps'] as int? ?? maxSteps;
    temperature = (j['temperature'] as num?)?.toDouble() ?? temperature;
    onboarded = j['onboarded'] as bool? ?? false;
    disabledSkills = {...(j['disabledSkills'] as List? ?? const []).cast<String>()};
    grantedSkills = {...(j['grantedSkills'] as List? ?? const []).cast<String>()};
  }

  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    notifyListeners();
    await _store.write(_key, {
      'themeMode': themeMode.name,
      'voice': voice,
      'hfToken': hfToken,
      'plannerId': plannerId,
      'routerId': routerId,
      'embedderId': embedderId,
      'thinking': thinking,
      'useRouter': useRouter,
      'useGpu': useGpu,
      'maxSteps': maxSteps,
      'temperature': temperature,
      'onboarded': onboarded,
      'disabledSkills': disabledSkills.toList(),
      'grantedSkills': grantedSkills.toList(),
    });
  }
}
