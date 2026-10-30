/// Offline unit conversion for common everyday units.
class Units {
  static const _groups = <String, Map<String, double>>{
    'length': {
      'mm': 0.001, 'cm': 0.01, 'm': 1, 'km': 1000,
      'in': 0.0254, 'ft': 0.3048, 'yd': 0.9144, 'mi': 1609.344,
    },
    'mass': {'mg': 1e-6, 'g': 0.001, 'kg': 1, 't': 1000, 'oz': 0.0283495, 'lb': 0.453592, 'st': 6.35029},
    'volume': {
      'ml': 0.001, 'l': 1, 'tsp': 0.00492892, 'tbsp': 0.0147868, 'floz': 0.0295735,
      'cup': 0.236588, 'pt': 0.473176, 'qt': 0.946353, 'gal': 3.78541,
    },
    'speed': {'m/s': 1, 'km/h': 0.277778, 'mph': 0.44704, 'kn': 0.514444},
    'data': {'b': 1, 'kb': 1e3, 'mb': 1e6, 'gb': 1e9, 'tb': 1e12, 'kib': 1024, 'mib': 1048576, 'gib': 1073741824},
    'time': {'ms': 0.001, 's': 1, 'min': 60, 'h': 3600, 'day': 86400, 'week': 604800},
  };

  static const _aliases = {
    'meter': 'm', 'meters': 'm', 'metre': 'm', 'kilometer': 'km', 'kilometers': 'km', 'kms': 'km',
    'centimeter': 'cm', 'centimeters': 'cm', 'millimeter': 'mm', 'inch': 'in', 'inches': 'in',
    'foot': 'ft', 'feet': 'ft', 'yard': 'yd', 'yards': 'yd', 'mile': 'mi', 'miles': 'mi',
    'gram': 'g', 'grams': 'g', 'kilogram': 'kg', 'kilograms': 'kg', 'kgs': 'kg', 'pound': 'lb',
    'pounds': 'lb', 'lbs': 'lb', 'ounce': 'oz', 'ounces': 'oz', 'stone': 'st',
    'liter': 'l', 'liters': 'l', 'litre': 'l', 'litres': 'l', 'milliliter': 'ml', 'cups': 'cup',
    'gallon': 'gal', 'gallons': 'gal', 'kph': 'km/h', 'kmh': 'km/h', 'knots': 'kn',
    'seconds': 's', 'sec': 's', 'minutes': 'min', 'mins': 'min', 'hour': 'h', 'hours': 'h', 'hr': 'h',
    'days': 'day', 'weeks': 'week',
    'c': 'celsius', '°c': 'celsius', 'f': 'fahrenheit', '°f': 'fahrenheit', 'k': 'kelvin',
  };

  static String normalise(String unit) {
    final u = unit.trim().toLowerCase();
    return _aliases[u] ?? u;
  }

  static double convert(double value, String from, String to) {
    final f = normalise(from), t = normalise(to);
    const temps = {'celsius', 'fahrenheit', 'kelvin'};
    if (temps.contains(f) && temps.contains(t)) {
      final c = switch (f) { 'fahrenheit' => (value - 32) * 5 / 9, 'kelvin' => value - 273.15, _ => value };
      return switch (t) { 'fahrenheit' => c * 9 / 5 + 32, 'kelvin' => c + 273.15, _ => c };
    }
    for (final g in _groups.values) {
      if (g.containsKey(f) && g.containsKey(t)) return value * g[f]! / g[t]!;
    }
    throw ArgumentError('Cannot convert $from to $to');
  }
}
