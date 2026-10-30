import 'dart:convert';

import '../core/runtime/engine_types.dart';

/// Parses tool calls out of model text for runtimes without native tool
/// calling. Understands three shapes:
///   ```tool_call {"name": "...", "arguments": {...}} ```   (our prompt format)
///   <start_function_call>call:name{key:<escape>v<escape>}<end_function_call>  (FunctionGemma)
///   [name(key="v", n=5)]                                   (Gemma 3 style)
class ToolCallParser {
  static int _seq = 0;

  static String _id() => 'tc${_seq++}';

  static ({List<ToolCallRequest> calls, String text}) parse(String text, Set<String> knownTools) {
    final calls = <ToolCallRequest>[];
    var rest = text;

    final fenced = RegExp(r'```(?:tool_call|tool_code|json)?\s*([\s\S]*?)```');
    for (final m in fenced.allMatches(text)) {
      final found = _fromJson(m.group(1)!, knownTools);
      if (found.isNotEmpty) {
        calls.addAll(found);
        rest = rest.replaceFirst(m.group(0)!, '');
      }
    }

    final fg = RegExp(r'<start_function_call>\s*call:(\w+)\{([\s\S]*?)\}\s*<end_function_call>');
    for (final m in fg.allMatches(text)) {
      if (!knownTools.contains(m.group(1))) continue;
      calls.add(ToolCallRequest(id: _id(), name: m.group(1)!, arguments: _functionGemmaArgs(m.group(2)!)));
      rest = rest.replaceFirst(m.group(0)!, '');
    }

    if (calls.isEmpty) {
      final trimmed = text.trim();
      final py = RegExp(r'^\[\s*(\w+)\((.*)\)\s*\]$', dotAll: true).firstMatch(trimmed);
      if (py != null && knownTools.contains(py.group(1))) {
        calls.add(ToolCallRequest(id: _id(), name: py.group(1)!, arguments: _pythonArgs(py.group(2)!)));
        rest = '';
      } else if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        final bare = _fromJson(trimmed, knownTools);
        if (bare.isNotEmpty) {
          calls.addAll(bare);
          rest = '';
        }
      }
    }
    return (calls: calls, text: rest.trim());
  }

  static List<ToolCallRequest> _fromJson(String body, Set<String> known) {
    Object? decoded;
    try {
      decoded = jsonDecode(body.trim());
    } on FormatException {
      return const [];
    }
    final items = decoded is List ? decoded : [decoded];
    final out = <ToolCallRequest>[];
    for (final item in items) {
      if (item is! Map) continue;
      final fn = item['function'] is Map ? item['function'] as Map : item;
      final name = fn['name'];
      if (name is! String || !known.contains(name)) continue;
      var args = fn['arguments'] ?? fn['parameters'] ?? const {};
      if (args is String) {
        try {
          args = jsonDecode(args);
        } on FormatException {
          args = const {};
        }
      }
      out.add(ToolCallRequest(id: _id(), name: name, arguments: Map<String, dynamic>.from(args as Map)));
    }
    return out;
  }

  static Object _scalar(String raw) {
    final v = raw.trim();
    if (v == 'true') return true;
    if (v == 'false') return false;
    return num.tryParse(v) ?? v;
  }

  static Map<String, dynamic> _functionGemmaArgs(String body) {
    final args = <String, dynamic>{};
    final re = RegExp(r'(\w+):(?:<escape>([\s\S]*?)<escape>|([^,]*))');
    for (final m in re.allMatches(body)) {
      args[m.group(1)!] = m.group(2) ?? _scalar(m.group(3) ?? '');
    }
    return args;
  }

  static Map<String, dynamic> _pythonArgs(String body) {
    final args = <String, dynamic>{};
    final re = RegExp(r'''(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^,]+)''');
    for (final m in re.allMatches(body)) {
      final v = m.group(2)!.trim();
      args[m.group(1)!] = (v.startsWith('"') || v.startsWith("'"))
          ? v.substring(1, v.length - 1).replaceAll(r'\"', '"')
          : _scalar(v);
    }
    return args;
  }
}
