import 'package:prismarine_math/libm.dart' as libm;

/// An automation curve of points sorted by x. The value holds past either
/// end. The shape s of a point bends the segment that it starts as
/// y0 + (y1 − y0)·(e^(k·s·t) − 1)/(e^(k·s) − 1) with k = 7, a line at s = 0.
class Curve {
  Curve(List<(double x, double y, double shape)> points)
    : _points = [...points]..sort((a, b) => a.$1.compareTo(b.$1));

  factory Curve.fromJson(List<Map<String, Object?>> points) => Curve([
    for (final p in points)
      (
        (p['x'] as num).toDouble(),
        (p['y'] as num).toDouble(),
        ((p['shape'] as num?) ?? 0).toDouble(),
      ),
  ]);

  static const shapeK = 7.0;
  final List<(double, double, double)> _points;

  bool get isEmpty => _points.isEmpty;

  /// The points as sorted (x, y, shape).
  List<(double, double, double)> get points => _points;

  double at(double x) {
    final p = _points;
    if (p.isEmpty) return 0;
    if (x <= p.first.$1) return p.first.$2;
    if (x >= p.last.$1) return p.last.$2;
    var i = 0;
    while (p[i + 1].$1 <= x) {
      i++;
    }
    final (x0, y0, s) = p[i];
    final (x1, y1, _) = p[i + 1];
    final t = x1 > x0 ? (x - x0) / (x1 - x0) : 1.0;
    return y0 + (y1 - y0) * shape(t, s);
  }

  /// Returns the shaped fraction of a segment at [t] in [0, 1].
  static double shape(double t, double s) {
    final k = shapeK * s;
    if (k.abs() < 1e-6) return t;
    return (libm.exp(k * t) - 1) / (libm.exp(k) - 1);
  }
}

/// A piecewise linear map from UI units to property units. The value holds
/// past either end.
class PiecewiseMap {
  PiecewiseMap(List<(double, double)> points)
    : _points = [...points]..sort((a, b) => a.$1.compareTo(b.$1));
  final List<(double, double)> _points;

  /// The points as sorted (x, y).
  List<(double, double)> get points => _points;

  double map(double x) {
    final p = _points;
    if (p.isEmpty) return x;
    if (x <= p.first.$1) return p.first.$2;
    if (x >= p.last.$1) return p.last.$2;
    var i = 0;
    while (p[i + 1].$1 <= x) {
      i++;
    }
    final (x0, y0) = p[i];
    final (x1, y1) = p[i + 1];
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
  }
}

extension PiecewiseMapUi on PiecewiseMap {
  /// Returns the UI value that maps to [y], clamped to the ends. The map is
  /// monotonic.
  double unmap(double y) {
    final p = _points;
    if (p.isEmpty) return y;
    final up = p.last.$2 >= p.first.$2;
    for (var i = 0; i + 1 < p.length; i++) {
      final (x0, y0) = p[i];
      final (x1, y1) = p[i + 1];
      final inside = up ? y >= y0 && y <= y1 : y <= y0 && y >= y1;
      if (inside) return y1 == y0 ? x0 : x0 + (x1 - x0) * (y - y0) / (y1 - y0);
    }
    return (up ? y < p.first.$2 : y > p.first.$2) ? p.first.$1 : p.last.$1;
  }

  /// The width of the UI range.
  double get span => _points.isEmpty ? 0 : _points.last.$1 - _points.first.$1;
}

/// Converts dB to a linear gain. −80 dB and less is silence.
double dbToGain(double db) => db <= -80 ? 0 : libm.dpow(10, db / 20);
