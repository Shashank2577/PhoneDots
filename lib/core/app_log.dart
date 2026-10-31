import 'dart:async';

import 'package:flutter/foundation.dart';

import 'storage/json_store.dart';

/// What the app did, step by step: model downloads and copies (each step of
/// the shared store), model loads, and errors. Shown on Settings → Logs, where
/// it is copied into a bug report. Kept on the phone only, newest last, at
/// most [limit] lines.
class AppLog extends ChangeNotifier {
  AppLog(this._store);

  static const _key = 'app-log';
  static const limit = 500;

  final JsonStore? _store;
  final List<String> _lines = [];
  Timer? _save;

  List<String> get lines => List.unmodifiable(_lines);

  Future<void> load() async {
    final raw = await _store?.read(_key) as List?;
    if (raw != null) _lines.addAll(raw.cast<String>());
  }

  /// Adds `2026-10-31 16:59:22 [models] gemma-4-e2b: checksum ok`.
  void add(String area, String message) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _lines.add('${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} [$area] $message');
    if (_lines.length > limit) _lines.removeRange(0, _lines.length - limit);
    notifyListeners();
    // Saved a moment later, so a download doesn't write once per line.
    _save ??= Timer(const Duration(seconds: 1), () {
      _save = null;
      unawaited(_store?.write(_key, _lines));
    });
  }

  /// A header line, then every line.
  String text({required String header}) => '$header\n${_lines.join('\n')}\n';

  Future<void> clear() async {
    _lines.clear();
    notifyListeners();
    await _store?.delete(_key);
  }
}
