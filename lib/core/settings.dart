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

  /// Read the public preview of links you paste or share (one request per link, logged).
  bool readLinks = true;

  /// Summarise shared posts with Gemma as soon as they arrive.
  bool autoSummarise = true;

  /// Free fallback: ask Jina Reader for a page's text when its preview says too
  /// little. Sends the link to Jina, so it is off unless the user turns it on.
  bool webReader = false;

  /// Optional free keys. YouTube Data API: full video details (10,000 free
  /// units a day, one per video). Jina: higher reader limits.
  String youtubeKey = '';
  String jinaKey = '';

  /// Send a crash report (no chats, no personal data) to [crashReportUrl]
  /// after the app crashed. Off by default; nothing is sent without a URL.
  bool crashReports = false;
  String crashReportUrl = '';
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
    themeMode = ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system;
    voice = j['voice'] as String? ?? voice;
    hfToken = j['hfToken'] as String? ?? '';
    plannerId = j['plannerId'] as String? ?? plannerId;
    routerId = j['routerId'] as String? ?? routerId;
    embedderId = j['embedderId'] as String? ?? embedderId;
    thinking = j['thinking'] as bool? ?? thinking;
    useRouter = j['useRouter'] as bool? ?? useRouter;
    readLinks = j['readLinks'] as bool? ?? readLinks;
    autoSummarise = j['autoSummarise'] as bool? ?? autoSummarise;
    webReader = j['webReader'] as bool? ?? webReader;
    youtubeKey = j['youtubeKey'] as String? ?? '';
    jinaKey = j['jinaKey'] as String? ?? '';
    crashReports = j['crashReports'] as bool? ?? false;
    crashReportUrl = j['crashReportUrl'] as String? ?? '';
    useGpu = j['useGpu'] as bool? ?? useGpu;
    maxSteps = (j['maxSteps'] as int? ?? maxSteps).clamp(1, 12);
    temperature = ((j['temperature'] as num?)?.toDouble() ?? temperature).clamp(0.0, 1.2);
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
      'readLinks': readLinks,
      'autoSummarise': autoSummarise,
      'webReader': webReader,
      'youtubeKey': youtubeKey,
      'jinaKey': jinaKey,
      'crashReports': crashReports,
      'crashReportUrl': crashReportUrl,
      'useGpu': useGpu,
      'maxSteps': maxSteps,
      'temperature': temperature,
      'onboarded': onboarded,
      'disabledSkills': disabledSkills.toList(),
      'grantedSkills': grantedSkills.toList(),
    });
  }
}
