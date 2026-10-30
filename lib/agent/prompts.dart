import 'dart:convert';

import '../core/runtime/engine_types.dart';
import '../skills/skill.dart';

class Prompts {
  static const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  static String system({
    required DateTime now,
    required List<Attachment> attachments,
    required String memory,
    required List<ToolSpec> tools,
    required bool nativeTools,
  }) {
    final b = StringBuffer()
      ..writeln('You are PhoneDots, a private assistant that runs entirely on the user\'s phone. '
          'You have no internet access. Everything you do stays on this device.')
      ..writeln('Now: ${_weekdays[now.weekday - 1]} ${now.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} '
          '(UTC${now.timeZoneOffset.isNegative ? '-' : '+'}${now.timeZoneOffset.inHours.abs()}).')
      ..writeln('Use a tool whenever one can do the job better than you (maths, the phone, the user\'s files, audio, photos). '
          'Never invent tool results. If a tool fails, say so plainly. '
          'Keep answers short and direct; use bullet points for lists.');
    if (attachments.isNotEmpty) {
      b.writeln('\nAttachments in this conversation (pass the id to tools):');
      for (final a in attachments) {
        b.writeln('- ${a.id}: ${a.kind}, "${a.name}"');
      }
    }
    if (memory.isNotEmpty) {
      b
        ..writeln('\nThings the user asked you to remember:')
        ..writeln(memory);
    }
    if (!nativeTools && tools.isNotEmpty) {
      b
        ..writeln('\nTools:')
        ..writeln(jsonEncode(tools.map((t) => t.toJson()).toList()))
        ..writeln('To call a tool, reply with only this and nothing else:')
        ..writeln('```tool_call\n{"name": "<tool name>", "arguments": {...}}\n```')
        ..writeln('You will then receive the result and can answer.');
    }
    return b.toString();
  }

  /// FunctionGemma's expected developer prompt.
  static const router = 'You are a model that can do function calling with the following functions';
}
