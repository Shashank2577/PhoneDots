import 'dart:convert';

/// Pulls the first JSON object out of model text (handles ``` fences and
/// leading prose).
Map<String, dynamic>? extractJson(String text) {
  final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
  final candidate = fenced?.group(1) ?? text;
  final start = candidate.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  for (var i = start; i < candidate.length; i++) {
    final c = candidate[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') inString = true;
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        try {
          final v = jsonDecode(candidate.substring(start, i + 1));
          return v is Map ? Map<String, dynamic>.from(v) : null;
        } on FormatException {
          return null;
        }
      }
    }
  }
  return null;
}
