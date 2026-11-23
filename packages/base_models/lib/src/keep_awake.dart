import 'package:flutter/services.dart';

/// Keeps the app working while a model downloads or the AI writes an answer.
///
/// - Android: an ongoing notification ("PhoneDots · downloading Gemma 4 E2B ·
///   34%") from a foreground service, plus a wake lock, so the app isn't paused
///   in the background and the phone doesn't sleep mid-way.
/// - iOS: the screen is kept from locking while the app is open, and if the
///   user leaves, iOS gives the extra time it allows (about 30 seconds).
/// - macOS: the Mac doesn't sleep or slow the app down.
/// - Elsewhere (web, Windows, Linux, tests): nothing to do.
///
/// The model store does this for every model install by itself; apps call
/// [during] around AI answers.
class KeepAwake {
  KeepAwake._();

  static const _channel = MethodChannel('base/models');

  static Future<void> begin(String key, String text, {bool ai = false}) => _call('keepAwakeBegin', {'key': key, 'text': text, 'ai': ai});

  /// Progress 0..1 (shown on Android's notification).
  static Future<void> update(String key, double? progress, {String? text}) =>
      _call('keepAwakeUpdate', {'key': key, 'progress': progress, 'text': ?text});

  static Future<void> end(String key) => _call('keepAwakeEnd', {'key': key});

  /// Runs [work] with the app kept awake, e.g.
  /// `KeepAwake.during('answer', 'writing an answer', () => engine.generate(...), ai: true)`.
  static Future<T> during<T>(String key, String text, Future<T> Function() work, {bool ai = false}) async {
    await begin(key, text, ai: ai);
    try {
      return await work();
    } finally {
      await end(key);
    }
  }

  static Future<void> _call(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on Object {
      // No plugin here (web, desktop without it, tests): nothing to keep awake.
    }
  }
}
