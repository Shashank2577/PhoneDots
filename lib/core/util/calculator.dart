import 'dart:math' as math;

/// Safe arithmetic evaluator: + - * / ^ %, parentheses, unary minus and a
/// few functions. No eval, no variables.
class Calculator {
  static double evaluate(String input) {
    final p = _Parser(input.replaceAll(',', '').replaceAll('×', '*').replaceAll('÷', '/'));
    final v = p.expression();
    p.skipSpaces();
    if (!p.done) throw FormatException('Unexpected "${p.rest}"');
    return v;
  }

  static String format(double v) {
    if (v.isNaN || v.isInfinite) return '$v';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return double.parse(v.toStringAsPrecision(12)).toString();
  }
}

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  bool get done => i >= s.length;
  String get rest => s.substring(i);

  void skipSpaces() {
    while (!done && s[i] == ' ') {
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

  double expression() {
    var v = term();
    while (true) {
      if (eat('+')) {
        v += term();
      } else if (eat('-')) {
        v -= term();
      } else {
        return v;
      }
    }
  }

  double term() {
    var v = power();
    while (true) {
      if (eat('*')) {
        v *= power();
      } else if (eat('/')) {
        v /= power();
      } else if (eat('%')) {
        // "50%" alone means 0.5; "a % b" is modulo.
        skipSpaces();
        if (done || s[i] == ')' || '+-*/'.contains(s[i])) {
          v /= 100;
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
    final word = RegExp(r'[a-z]+').matchAsPrefix(s, i);
    if (word != null) {
      final name = word.group(0)!;
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
