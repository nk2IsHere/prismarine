import 'dart:math' as math;

import 'package:prismarine_math/clamp.dart';
import 'package:prismarine_math/libm.dart' as libm;
import 'package:prismarine_pad/prismarine_pad.dart';
import 'package:prismarine_pbr/builder.dart';
import 'package:vector_math/vector_math_64.dart';

/// A camera that flies through the scene. The view turns with [yaw] around
/// the up axis and with [pitch] up and down.
class FlyCamera {
  final position = Vector3.zero();
  double yaw = 0, pitch = 0;

  /// The speed in metres per second, changed by the mouse wheel.
  double speed = 2.5;

  /// Radians of turn per pixel of mouse movement.
  double mouseTurn = 0.004;

  /// The keys held down, by the direction they move in.
  bool forward = false, back = false, left = false, right = false;
  bool up = false, down = false, fast = false;

  double _lookX = 0, _lookY = 0;
  final _dir = Vector3.zero(), _side = Vector3.zero();
  static final _worldUp = Vector3(0, 1, 0);

  /// Adds a mouse movement of [dx] and [dy] pixels, y down.
  void look(double dx, double dy) {
    _lookX += dx;
    _lookY += dy;
  }

  /// Multiplies the speed by [factor], within limits.
  void scaleSpeed(double factor) =>
      speed = clampDouble(speed * factor, 0.1, 50);

  /// Places the camera at the world matrix [world] of a scene camera.
  void place(Matrix4 world) {
    final s = world.storage;
    position.setValues(s[12], s[13], s[14]);
    // The camera looks along the negative z axis of its node.
    final fx = -s[8], fy = -s[9], fz = -s[10];
    final len = math.sqrt(fx * fx + fy * fy + fz * fz);
    pitch = libm.asin(clampDouble(fy / len, -1, 1));
    yaw = libm.atan2(-fx, -fz);
  }

  /// Places the camera outside the box [min] to [max], turned by [turn]
  /// radians around the up axis and looking down at its centre by [down]
  /// radians, at the distance where a field of view of [yfov] holds the box.
  void frame(
    Vector3 min,
    Vector3 max,
    double yfov, {
    double turn = 0,
    double down = 0.35,
  }) {
    final radius = max.distanceTo(min) / 2;
    final distance = radius / math.sin(yfov / 2) * 1.05;
    yaw = turn;
    pitch = -down;
    _direction(_dir);
    position
      ..setFrom(min)
      ..add(max)
      ..scale(0.5)
      ..addScaled(_dir, -distance);
    speed = clampDouble(radius / 4, 0.1, 50);
  }

  /// Steps the camera by [dt] seconds with the mouse movement so far and
  /// the pad reading [pad], then writes its view into [out].
  void step(double dt, PadState pad, PbrCamera out) {
    yaw -= _lookX * mouseTurn;
    pitch -= _lookY * mouseTurn;
    _lookX = _lookY = 0;
    if (pad.connected) {
      yaw -= _dead(pad.rightX) * 2.2 * dt;
      pitch += _dead(pad.rightY) * 1.6 * dt;
    }
    pitch = clampDouble(pitch, -1.5, 1.5);
    _direction(_dir);
    _side.setValues(libm.cos(yaw), 0, -libm.sin(yaw));
    var move = 0.0, strafe = 0.0, lift = 0.0;
    if (forward) move += 1;
    if (back) move -= 1;
    if (right) strafe += 1;
    if (left) strafe -= 1;
    if (up) lift += 1;
    if (down) lift -= 1;
    var boost = fast ? 4.0 : 1.0;
    if (pad.connected) {
      move += _dead(pad.leftY);
      strafe += _dead(pad.leftX);
      lift += pad.rightTrigger - pad.leftTrigger;
      if (pad.pressed(PadButton.leftStick)) boost = 4;
    }
    final d = speed * boost * dt;
    position
      ..addScaled(_dir, move * d)
      ..addScaled(_side, strafe * d)
      ..addScaled(_worldUp, lift * d);
    out.position.setFrom(position);
    lookAlong(out.view, position, _dir, _worldUp);
  }

  void _direction(Vector3 out) => out.setValues(
    -libm.sin(yaw) * libm.cos(pitch),
    libm.sin(pitch),
    -libm.cos(yaw) * libm.cos(pitch),
  );

  static double _dead(double v) => v.abs() < 0.15 ? 0 : v;
}
