import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'ledger.dart';
import 'settings.dart';

/// Sends a crash report to the user's chosen server, only when they turned
/// it on and gave an https address. The report holds the crash, the app
/// version, the phone model and the recent diagnostics log (which never
/// contains chat text or personal data).
class CrashReporter {
  CrashReporter({required this.settings, required this.ledger, http.Client? client})
    : _client = client ?? http.Client();

  final AppSettings settings;
  final Ledger ledger;
  final http.Client _client;

  static const appVersion = '0.7.0';

  bool get enabled {
    final u = Uri.tryParse(settings.crashReportUrl.trim());
    return settings.crashReports && u != null && u.scheme == 'https' && u.host.isNotEmpty;
  }

  Map<String, dynamic> report(String crash, {Map<String, Object?> device = const {}}) => {
    'app': 'PhoneDots',
    'version': appVersion,
    'time': DateTime.now().toUtc().toIso8601String(),
    'device': device,
    'crash': crash,
    'log': appLog.export(errorsOnly: false, maxChars: 60000),
  };

  /// Returns true when the server accepted the report.
  Future<bool> send(String crash, {Map<String, Object?> device = const {}}) async {
    if (!enabled) return false;
    final url = Uri.parse(settings.crashReportUrl.trim());
    try {
      await ledger.record('crash', 'Sent a crash report to ${url.host}', network: true);
      final res = await _client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(report(crash, device: device)),
          )
          .timeout(const Duration(seconds: 20));
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      ok
          ? appLog.info('crash', 'report sent', {'status': res.statusCode})
          : appLog.warn('crash', 'report refused', {'status': res.statusCode});
      return ok;
    } catch (e) {
      appLog.warn('crash', 'report not sent', {'error': '$e'});
      return false;
    }
  }
}
