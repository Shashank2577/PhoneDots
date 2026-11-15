import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_services.dart';
import '../../app_state.dart';
import '../../core/app_log.dart';
import '../../core/crash_reporter.dart';
import '../../core/models/model_catalog.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

/// What PhoneDots did, step by step, with timings and errors. Kept on the
/// phone; shared only when you tap "share".
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _errorsOnly = false;
  late final _url = TextEditingController(text: AppScope.services(context).settings.crashReportUrl);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Map<String, Object?> _header() {
    final s = AppScope.services(context);
    final d = s.models.device;
    return {
      'app': 'PhoneDots ${CrashReporter.appVersion}',
      'platform': s.platform,
      'modelStore': AppServices.sharedModelsPath ?? 'none (demo)',
      'device': d.model,
      'chip': d.socName,
      'ramMb': d.totalRamMb,
      'brain': modelById(s.settings.plannerId)?.name ?? s.settings.plannerId,
      'brainReady': s.models.isReady(s.settings.plannerId),
      'brainLoaded': s.models.loadedPlanner,
      'fastPath': s.settings.useRouter ? (modelById(s.settings.routerId)?.name ?? s.settings.routerId) : 'off',
      'routerReady': s.models.isReady(s.settings.routerId),
      'gpu': s.settings.useGpu,
      'grantedSkills': s.settings.grantedSkills.join(', '),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([appLog, s.settings]),
      builder: (context, _) {
        final shown = [
          for (final e in appLog.entries.reversed)
            if (!_errorsOnly || e.level != LogLevel.info) e,
        ];
        return HandPage(
          children: [
            const PageIntro(
              'diagnostics',
              'Every step PhoneDots takes, with timings and errors, so a problem can be traced. It never records what '
                  'you wrote, the answers, contact names or messages. It stays here unless you share it.',
            ),
            if (appLog.lastCrash != null) ...[Warning(appLog.lastCrash!), const SizedBox(height: 12)],
            Caption(
              '${appLog.entries.length} ${appLog.entries.length == 1 ? 'entry' : 'entries'} · '
              '${appLog.errorCount} ${appLog.errorCount == 1 ? 'error' : 'errors'}',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PillButton(
                  'share the log',
                  leading: Doodle.share,
                  onTap: () =>
                      s.device.invoke('share.text', {'text': appLog.export(header: _header(), maxChars: 200000)}),
                ),
                HandLink(
                  'copy',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: appLog.export(header: _header())));
                    toast(context, 'log copied');
                  },
                ),
                HandLink(
                  'clear',
                  color: p.redPen,
                  onTap: () async {
                    if (await confirmDialog(context, title: 'clear the log?', confirm: 'clear', destructive: true)) {
                      await appLog.clear();
                    }
                  },
                ),
              ],
            ),
            const SectionHead('crash reports'),
            SwitchRow(
              title: 'send crash reports',
              body: s.settings.crashReportUrl.trim().isEmpty
                  ? 'After a crash, send the report and recent log (no chats, no personal data) to your server. '
                        'Add the server address below first.'
                  : 'After a crash, send the report and recent log (no chats, no personal data) to '
                        '${Uri.tryParse(s.settings.crashReportUrl)?.host ?? 'your server'}. Each report is listed under privacy.',
              value: s.settings.crashReports,
              onChanged: (v) => s.settings.update((x) => x.crashReports = v),
            ),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              onChanged: (v) => s.settings.update((x) => x.crashReportUrl = v.trim()),
              decoration: const InputDecoration(hintText: 'https://your-server/crash (optional)'),
            ),
            const SectionHead('latest first'),
            ChoicePill(
              _errorsOnly ? 'showing problems only' : 'showing everything',
              leading: _errorsOnly ? Doodle.exclaim : Doodle.eye,
              selected: _errorsOnly,
              onTap: () => setState(() => _errorsOnly = !_errorsOnly),
            ),
            const SizedBox(height: 8),
            if (shown.isEmpty) const HandEmpty(title: 'nothing logged yet', doodle: Doodle.squiggle),
            for (final e in shown.take(400)) _Entry(e),
          ],
        );
      },
    );
  }
}

/// One log line: mono 13 in ink, problems with a red "!" in front.
class _Entry extends StatelessWidget {
  const _Entry(this.e);
  final LogEntry e;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final mono = context.type.mono;
    final t = e.time.toIso8601String().substring(11, 19);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: e.level == LogLevel.info
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: DoodleIcon(
                      Doodle.exclaim,
                      size: 14,
                      stroke: 2.4,
                      color: e.level == LogLevel.error ? p.redPen : p.ink,
                      semanticLabel: e.level.name,
                    ),
                  ),
          ),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                style: mono,
                children: [
                  TextSpan(text: '$t  ', style: TextStyle(color: p.pencil)),
                  TextSpan(text: '${e.tag} · ${e.message}'),
                  if (e.data != null && e.data!.isNotEmpty)
                    TextSpan(
                      text: '\n${e.data!.entries.map((x) => '${x.key}: ${x.value}').join('  ·  ')}',
                      style: TextStyle(color: p.pencil),
                    ),
                ],
              ),
              maxLines: e.level == LogLevel.error ? 14 : 5,
            ),
          ),
        ],
      ),
    );
  }
}
