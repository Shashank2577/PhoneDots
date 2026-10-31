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
      final py = trimmed.startsWith('[') && trimmed.endsWith(']') ? _pythonCalls(trimmed, knownTools) : null;
      if (py != null && py.isNotEmpty) {
        calls.addAll(py);
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

  /// `[a(x=1), b()]`: splits top-level calls, respecting quotes and brackets.
  static List<ToolCallRequest>? _pythonCalls(String text, Set<String> known) {
    final body = text.substring(1, text.length - 1);
    final parts = <String>[];
    var depth = 0;
    String? quote;
    var start = 0;
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (quote != null) {
        if (ch == '\\') {
          i++;
        } else if (ch == quote) {
          quote = null;
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '(' || ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ')' || ch == ']' || ch == '}') {
        depth--;
      } else if (ch == ',' && depth == 0) {
        parts.add(body.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(body.substring(start));
    final out = <ToolCallRequest>[];
    for (final p in parts) {
      final m = RegExp(r'^\s*(\w+)\(([\s\S]*)\)\s*$').firstMatch(p);
      if (m == null) return null;
      if (!known.contains(m.group(1))) continue;
      out.add(ToolCallRequest(id: _id(), name: m.group(1)!, arguments: _pythonArgs(m.group(2)!)));
    }
    return out;
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
      out.add(ToolCallRequest(id: _id(), name: name, arguments: args is Map ? Map<String, dynamic>.from(args) : {}));
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
