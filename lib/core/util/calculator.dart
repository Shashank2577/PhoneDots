import 'dart:math' as math;

/// Safe arithmetic evaluator: + - * / ^ %, parentheses, unary minus and a
/// few functions. No eval, no variables.
class Calculator {
  static double evaluate(String input) {
    var s = input.replaceAll('×', '*').replaceAll('÷', '/').replaceAll('\u2212', '-');
    // "18% of 2450" is how people (and models) say it.
    s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*%\s*of\b', caseSensitive: false), (m) => '(${m.group(1)}/100)*');
    // Commas are thousands separators only ("1,234,567"); "2,5" is ambiguous.
    s = s.replaceAllMapped(RegExp(r'\d{1,3}(?:,\d{3})+(?![\d,])'), (m) => m.group(0)!.replaceAll(',', ''));
    if (s.contains(',')) throw const FormatException('Use a dot for decimals (2.5, not 2,5)');
    final p = _Parser(s);
    final v = p.expression();
    p.skipSpaces();
    if (!p.done) throw FormatException('Unexpected "${p.rest}"');
    return v;
  }

  static String format(double v) {
    if (v.isNaN || v.isInfinite) return '$v';
    if (v == 0) return '0';
    // Whole numbers print exactly, without a trailing ".0" or exponent.
    if (v == v.roundToDouble() && v.abs() < 1e21) return BigInt.from(v).toString();
    final p = double.parse(v.toStringAsPrecision(12));
    final str = p.toString();
    if (!str.contains('e')) return str;
    // Tiny numbers: plain decimals rather than "1e-6".
    return p.abs() >= 1e-12 ? p.toStringAsFixed(15).replaceFirst(RegExp(r'0+$'), '') : str;
  }
}

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  bool get done => i >= s.length;
  String get rest => s.substring(i);

  void skipSpaces() {
    while (!done && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
      i++;
    }
  }

  bool eat(String c) {
    skipSpaces();
    if (!done && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  /// Set when the last term was a bare percentage ("10%"), so "200 + 10%"
  /// adds ten percent of 200, as on a pocket calculator.
  bool _percent = false;
  int _depth = 0;

  double expression() {
    if (++_depth > 200) throw const FormatException('Too deeply nested');
    try {
      return _expression();
    } finally {
      _depth--;
    }
  }

  double _expression() {
    var v = term();
    while (true) {
      if (eat('+')) {
        final t = term();
        v = _percent ? v + v * t : v + t;
      } else if (eat('-')) {
        final t = term();
        v = _percent ? v - v * t : v - t;
      } else {
        return v;
      }
    }
  }

  double term() {
    var v = power();
    _percent = false;
    while (true) {
      if (eat('*')) {
        v *= power();
        _percent = false;
      } else if (eat('/')) {
        v /= power();
        _percent = false;
      } else if (eat('%')) {
        // "50%" alone means 0.5; "a % b" is modulo.
        skipSpaces();
        if (done || s[i] == ')' || '+-*/'.contains(s[i])) {
          v /= 100;
          _percent = true;
        } else {
          v %= power();
        }
      } else {
        return v;
      }
    }
  }

  double power() {
    final base = unary();
    if (eat('^')) return math.pow(base, power()).toDouble();
    return base;
  }

  double unary() {
    if (eat('-')) return -unary();
    if (eat('+')) return unary();
    return primary();
  }

  static final _fns = <String, double Function(double)>{
    'sqrt': math.sqrt,
    'sin': math.sin,
    'cos': math.cos,
    'tan': math.tan,
    'log': (x) => math.log(x) / math.ln10,
    'ln': math.log,
    'abs': (x) => x.abs(),
    'round': (x) => x.roundToDouble(),
  };

  double primary() {
    skipSpaces();
    if (eat('(')) {
      final v = expression();
      if (!eat(')')) throw const FormatException('Missing )');
      return v;
    }
    final word = RegExp(r'[a-zA-Z]+').matchAsPrefix(s, i);
    if (word != null) {
      final name = word.group(0)!.toLowerCase();
      i = word.end;
      if (name == 'pi') return math.pi;
      if (name == 'e') return math.e;
      final fn = _fns[name];
      if (fn == null) throw FormatException('Unknown function $name');
      if (!eat('(')) throw FormatException('Expected ( after $name');
      final v = expression();
      if (!eat(')')) throw const FormatException('Missing )');
      return fn(v);
    }
    final num = RegExp(r'\d+(\.\d+)?|\.\d+').matchAsPrefix(s, i);
    if (num == null) throw FormatException(done ? 'Unexpected end' : 'Unexpected "${s[i]}"');
    i = num.end;
    return double.parse(num.group(0)!);
  }
}
