import 'package:flutter/services.dart';

import '../util/files.dart';
import 'engines.dart';

/// Handles the actions Dart can do on every platform (clipboard, clock,
/// reading text files) and forwards the rest to the native bridge.
class DartDeviceActions implements DeviceActions {
  DartDeviceActions(this.native);

  final DeviceActions native;

  @override
  bool get isDemo => native.isDemo;

  static const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  @override
  Future<Map<String, dynamic>> invoke(String action, Map<String, dynamic> args) async {
    switch (action) {
      case 'clipboard.set':
        await Clipboard.setData(ClipboardData(text: '${args['text'] ?? ''}'));
        return {'ok': true};
      case 'clipboard.get':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return {'text': data?.text ?? ''};
      case 'datetime':
        final now = DateTime.now();
        return {
          'iso': now.toIso8601String(),
          'weekday': _weekdays[now.weekday - 1],
          'timezone': now.timeZoneName,
          'utc_offset_minutes': now.timeZoneOffset.inMinutes,
          'summary': '${_weekdays[now.weekday - 1]} ${now.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}',
        };
      case 'file.readText':
        final text = await readTextFile('${args['path']}');
        return text == null ? {'error': 'Could not read that file as text.'} : {'text': text};
      default:
        return native.invoke(action, args);
    }
  }
}
