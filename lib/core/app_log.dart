import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'util/files.dart';

enum LogLevel { info, warn, error }

class LogEntry {
  LogEntry(this.time, this.level, this.tag, this.message, [this.data]);

  final DateTime time;
  final LogLevel level;

  /// Where it happened: agent, model, skill, device, share, app…
  final String tag;
  final String message;
  final Map<String, dynamic>? data;

  Map<String, dynamic> toJson() => {
    't': time.toIso8601String(),
    'l': level.name,
    'g': tag,
    'm': message,
    if (data != null && data!.isNotEmpty) 'd': data,
  };

  static LogEntry? fromJson(String line) {
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      return LogEntry(
        DateTime.parse(j['t'] as String),
        LogLevel.values.asNameMap()[j['l']] ?? LogLevel.info,
        j['g'] as String? ?? '',
        j['m'] as String? ?? '',
        (j['d'] as Map?)?.cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  String format() {
    final t = time.toIso8601String().substring(11, 23);
    final lvl = switch (level) {
      LogLevel.info => ' ',
      LogLevel.warn => '!',
      LogLevel.error => 'X',
    };
    final d = data == null || data!.isEmpty ? '' : '  ${jsonEncode(data)}';
    return '$t $lvl [$tag] $message$d';
  }
}

/// The app's own diagnostics log, kept on the phone.
///
/// It records what PhoneDots did and how long it took (model loads,
/// generations, skill calls, permissions, errors) so a problem can be traced.
/// It never records what you wrote, what the model answered, contact names or
/// message bodies: only sizes, names of skills and argument keys.
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const maxEntries = 3000;
  final List<LogEntry> entries = [];
  String? _path;
  String? _busyPath;
  final List<String> _pending = [];
  bool _writing = false;
  int _writtenSinceTrim = 0;

  /// Set when the previous session ended badly; shown once on the next launch.
  String? lastCrash;
  bool crashNoticeShown = false;

  int get errorCount => entries.where((e) => e.level == LogLevel.error).length;

  /// Opens the log file in [dir] and checks how the last session ended.
  Future<void> open(String? dir) async {
    if (dir == null) return;
    _path = '$dir/phonedots.log';
    _busyPath = '$dir/busy.marker';
    final text = await readTextFile(_path!, maxChars: 4000000);
    if (text != null) {
      for (final line in text.split('\n')) {
        final e = line.trim().isEmpty ? null : LogEntry.fromJson(line);
        if (e != null) entries.add(e);
      }
      if (entries.length > maxEntries) entries.removeRange(0, entries.length - maxEntries);
    }
    // A crash in the Android code is written to a file by the native handler.
    final nativeCrash = await readTextFile('$dir/native-crash.txt');
    if (nativeCrash != null && nativeCrash.trim().isNotEmpty) {
      lastCrash = 'PhoneDots crashed last time (Android):\n${nativeCrash.trim()}';
      error('crash', 'native crash in the previous session', {'report': _clip(nativeCrash, 4000)});
      await deleteFileAt('$dir/native-crash.txt');
    }
    // The app was killed while a model was working (usually out of memory).
    final busy = await readTextFile(_busyPath!);
    if (busy != null && busy.trim().isNotEmpty) {
      lastCrash ??=
          'PhoneDots closed unexpectedly last time while ${busy.trim()}. '
          'This usually means the phone ran out of memory; a smaller model or closing other apps helps.';
      error('crash', 'closed unexpectedly while ${busy.trim()}');
      await deleteFileAt(_busyPath!);
    }
    notifyListeners();
  }

  /// Marks a risky operation (model load or generation) so an abrupt end of
  /// the app during it is noticed on the next launch.
  Future<void> busy(String what) async {
    if (_busyPath == null) return;
    try {
      await deleteFileAt(_busyPath!);
      await appendTextFile(_busyPath!, what);
    } catch (_) {}
  }

  Future<void> idle() async {
    if (_busyPath == null) return;
    try {
      await deleteFileAt(_busyPath!);
    } catch (_) {}
  }

  void info(String tag, String message, [Map<String, dynamic>? data]) => _add(LogLevel.info, tag, message, data);

  void warn(String tag, String message, [Map<String, dynamic>? data]) => _add(LogLevel.warn, tag, message, data);

  void error(String tag, String message, [Map<String, dynamic>? data, Object? err, StackTrace? stack]) {
    _add(LogLevel.error, tag, message, {
      ...?data,
      if (err != null) 'error': _clip('$err', 1500),
      if (stack != null) 'stack': _clip('$stack', 3000),
    });
  }

  void _add(LogLevel level, String tag, String message, Map<String, dynamic>? data) {
    final e = LogEntry(DateTime.now(), level, tag, message, data);
    entries.add(e);
    if (entries.length > maxEntries) entries.removeRange(0, entries.length - maxEntries);
    if (kDebugMode) debugPrint('PhoneDots ${e.format()}');
    if (_path != null) {
      _pending.add(jsonEncode(e.toJson()));
      _flush();
    }
    notifyListeners();
  }

  Future<void> _flush() async {
    if (_writing || _path == null) return;
    _writing = true;
    try {
      while (_pending.isNotEmpty) {
        final batch = _pending.join('\n');
        final n = _pending.length;
        _pending.clear();
        await appendTextFile(_path!, '$batch\n');
        _writtenSinceTrim += n;
      }
      // Keep the file to the most recent entries.
      if (_writtenSinceTrim > 500) {
        _writtenSinceTrim = 0;
        await deleteFileAt(_path!);
        await appendTextFile(_path!, '${entries.map((e) => jsonEncode(e.toJson())).join('\n')}\n');
      }
    } catch (_) {
      // Logging must never break the app.
    } finally {
      _writing = false;
    }
  }

  Future<void> clear() async {
    entries.clear();
    lastCrash = null;
    if (_path != null) await deleteFileAt(_path!);
    notifyListeners();
  }

  /// Plain text for sharing: a header about the phone and app, then entries.
  String export({Map<String, Object?> header = const {}, bool errorsOnly = false, int maxChars = 300000}) {
    final b = StringBuffer('PhoneDots diagnostics · ${DateTime.now().toIso8601String()}\n');
    header.forEach((k, v) => b.writeln('$k: $v'));
    b.writeln('entries: ${entries.length}, errors: $errorCount\n');
    final lines = [
      for (final e in entries)
        if (!errorsOnly || e.level != LogLevel.info) e.format(),
    ];
    // Newest last; keep the end when it is too long.
    var body = lines.join('\n');
    if (body.length > maxChars) body = '…\n${body.substring(body.length - maxChars)}';
    b.write(body);
    return b.toString();
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
}

/// Shorthand used across the app.
final appLog = AppLog.instance;
