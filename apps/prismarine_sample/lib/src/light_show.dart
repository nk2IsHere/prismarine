import 'dart:math' as math;
import 'dart:typed_data';

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
  }) : lights = [for (var i = 0; i < count; i++) PointLight()],
       _scale = Float64List(count)..fillRange(0, count, 1) {
    for (var i = 0; i < count; i++) {
      final c = _colors[i % _colors.length];
      lights[i].color.setValues(c[0], c[1], c[2]);
    }
  }

  /// The paths for a scene with the box [min] to [max] and the punctual
  /// [lamps] of its files. With two or more point lamps the paths follow
  /// the box of the middle 80 % of the lamps on each axis, which marks the
  /// rooms that the scene lights. With [volume] each path shrinks until it
  /// keeps its light out of the walls and columns of the scene.
  factory LightShow.forScene(
    Vector3 min,
    Vector3 max,
    Iterable<ModelLight> lamps, {
    GiVolume? volume,
  }) {
    final show = LightShow._forBox(min, max, lamps);
    if (volume != null) show._fit(volume);
    return show;
  }

  factory LightShow._forBox(
    Vector3 min,
    Vector3 max,
    Iterable<ModelLight> lamps,
  ) {
    final points = [
      for (final l in lamps)
        if (l.type == 'point') l.position,
    ];
    if (points.length >= 2) {
      final lo = Vector3.zero(), hi = Vector3.zero();
      for (var a = 0; a < 3; a++) {
        final v = [for (final p in points) p[a]]..sort();
        lo[a] = v[(v.length * 0.1).floor()];
        hi[a] = v[((v.length - 1) * 0.9).ceil()];
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

  /// The factor of the radii of the path of each light.
  final Float64List _scale;

  /// The intensity of each light in candela and its range in metres.
  double intensity = 40, range = 12;

  /// Shrinks the path of each light in steps of 5 % until every point of
  /// it, at the top and the bottom of its height, is two cells or more from
  /// the surfaces of [v] and outside its closed parts.
  // alloc-cold: once for a scene.
  void _fit(GiVolume v) {
    bool clear(double x, double y, double z) {
      final cx = ((x - v.origin.x) / v.cell).floor();
      final cy = ((y - v.origin.y) / v.cell).floor();
      final cz = ((z - v.origin.z) / v.cell).floor();
      if (cx < 0 || cy < 0 || cz < 0 || cx >= v.nx || cy >= v.ny) return true;
      return cz >= v.nz || v.distanceAt(cx, cy, cz) >= 2;
    }

    for (var i = 0; i < lights.length; i++) {
      final high = i.isOdd;
      final y = high ? highY : lowY;
      while (_scale[i] > 0.05) {
        final rx = _radiusX(i), rz = _radiusZ(i);
        var ok = true;
        for (var k = 0; k < 64 && ok; k++) {
          final a = 2 * math.pi * k / 64;
          final x = center.x + rx * math.cos(a),
              z = center.z + rz * math.sin(a);
          ok = clear(x, y - 0.4, z) && clear(x, y, z) && clear(x, y + 0.4, z);
        }
        if (ok) break;
        _scale[i] -= 0.05;
      }
    }
  }

  double _radiusX(int i) => radiusX * (i.isOdd ? 0.85 : 1) * _scale[i];
  double _radiusZ(int i) => radiusZ * (i.isOdd ? 1 : 0.6) * _scale[i];

  /// Moves the lights to their places at [time] seconds.
  void place(double time) {
    final n = lights.length;
    for (var i = 0; i < n; i++) {
      final high = i.isOdd;
      final phase = 2 * math.pi * i / n;
      final speed = 0.12 + 0.03 * (i % 3);
      final a = time * speed * (high ? -1 : 1) + phase;
      final rx = _radiusX(i), rz = _radiusZ(i);
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
