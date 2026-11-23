import 'dart:math' as math;

import 'package:prismarine_math/libm.dart' as libm;
import 'package:prismarine_pbr/builder.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

/// Coloured point lights that move on ellipses through a scene: half of
/// them at [lowY] and half at [highY], around [center] with the half axes
/// [radiusX] and [radiusZ].
class LightShow {
  LightShow({
    required this.center,
    required this.radiusX,
    required this.radiusZ,
    required this.lowY,
    required this.highY,
    int count = 8,
  }) : lights = [for (var i = 0; i < count; i++) PointLight()] {
    for (var i = 0; i < count; i++) {
      final c = _colors[i % _colors.length];
      lights[i].color.setValues(c[0], c[1], c[2]);
    }
  }

  /// The paths for a scene with the box [min] to [max] and the punctual
  /// [lamps] of its files. With two or more point lamps the paths follow
  /// the box of the lamps, which marks the rooms that the scene lights.
  factory LightShow.forScene(
    Vector3 min,
    Vector3 max,
    Iterable<ModelLight> lamps,
  ) {
    final points = [
      for (final l in lamps)
        if (l.type == 'point') l.position,
    ];
    if (points.length >= 2) {
      final lo = Vector3.copy(points.first), hi = Vector3.copy(points.first);
      for (final p in points) {
        Vector3.min(lo, p, lo);
        Vector3.max(hi, p, hi);
      }
      return LightShow(
        center: (lo + hi)..scale(0.5),
        radiusX: (hi.x - lo.x) * 0.45,
        radiusZ: (hi.z - lo.z) * 0.4,
        lowY: lo.y * 0.35,
        highY: (lo.y + hi.y) / 2,
      );
    }
    final size = max - min;
    return LightShow(
      center: (min + max)..scale(0.5),
      radiusX: size.x * 0.3,
      radiusZ: size.z * 0.12,
      lowY: min.y + size.y * 0.08,
      highY: min.y + size.y * 0.33,
    );
  }

  final Vector3 center;
  final double radiusX, radiusZ, lowY, highY;
  final List<PointLight> lights;

  /// The intensity of each light in candela and its range in metres.
  double intensity = 40, range = 12;

  /// Moves the lights to their places at [time] seconds.
  void place(double time) {
    final n = lights.length;
    for (var i = 0; i < n; i++) {
      final high = i.isOdd;
      final phase = 2 * math.pi * i / n;
      final speed = 0.12 + 0.03 * (i % 3);
      final a = time * speed * (high ? -1 : 1) + phase;
      final rx = radiusX * (high ? 0.85 : 1), rz = radiusZ * (high ? 1 : 0.6);
      lights[i]
        ..position.setValues(
          center.x + rx * libm.cos(a),
          (high ? highY : lowY) + 0.4 * libm.sin(a * 2.3),
          center.z + rz * libm.sin(a),
        )
        ..intensity = intensity
        ..range = range;
    }
  }

  static const _colors = [
    [1.0, 0.25, 0.15],
    [1.0, 0.65, 0.2],
    [0.95, 0.9, 0.3],
    [0.3, 1.0, 0.35],
    [0.2, 0.85, 1.0],
    [0.25, 0.35, 1.0],
    [0.9, 0.3, 1.0],
    [1.0, 0.95, 0.9],
  ];
}
