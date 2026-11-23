import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:prismarine_debug/prismarine_debug.dart';
import 'package:prismarine_loop/prismarine_loop.dart';
import 'package:prismarine_math/libm.dart' as libm;
import 'package:prismarine_pad/prismarine_pad.dart';
import 'package:prismarine_pbr/prismarine_pbr.dart';

import 'fly_camera.dart';
import 'light_show.dart';
import 'sample_renderer.dart';
import 'sample_view.dart';

/// The size of the frames of the performance run.
const perfWidth = 1920, perfHeight = 1080;

/// Flies a fixed path through the scene for [seconds] at 1920 by 1080 and
/// writes the frame times with [FrameProfiler] into [out], then exits.
class PerfRun extends StatefulWidget {
  const PerfRun(this.renderer, {super.key, required this.seconds, this.out});
  final SampleRenderer renderer;
  final double seconds;
  final String? out;

  @override
  State<PerfRun> createState() => _PerfRunState();
}

class _PerfRunState extends State<PerfRun> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final SampleRenderer _r = widget.renderer;
  late final _profiler = FrameProfiler(
    widget.out ?? '${Directory.systemTemp.path}/prismarine_sample_perf',
  );
  late final LightShow _lights;
  final _fly = FlyCamera();
  final _view = PbrCamera();
  final _limiter = MetalFrameLimiter.create();
  final _repaint = ValueNotifier<int>(0);
  final _clock = Stopwatch();
  final _intervals = Float64List(100000);
  int _frames = 0, _lastUs = 0;
  double _build = 0, _record = 0, _gpu = 0;
  final _parts = Float64List(16);
  int _pointDraws = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _lights = LightShow.forScene(
      _r.builder.boundsMin,
      _r.builder.boundsMax,
      _r.lamps,
      volume: _r.builder.giVolume,
    );
    _r.builder.lights.addAll(_lights.lights);
    _r.onFrame = () => _repaint.value++;
    _clock.start();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _tick(Duration _) {
    if (_done) return;
    _limiter?.beginFrame();
    final now = _clock.elapsedMicroseconds;
    final t = now / 1e6;
    final dt = _frames == 0 ? 0.0 : (now - _lastUs) / 1000;
    _profiler.beginFrame(t: t, dt: dt / 1000);
    if (_frames > 0 && _frames <= _intervals.length) {
      _intervals[_frames - 1] = dt;
    }
    _lastUs = now;
    _frames++;
    _place(t);
    _lights.place(t);
    _fly.step(0, _noPad, _view);
    if (_r.inFlight < 2) {
      _r.submit(_view, perfWidth, perfHeight, dt: _frames < 2 ? 0 : dt / 1000);
    }
    final runner = _r.runner;
    _profiler
      ..add('build', _r.lastBuildMs)
      ..add('record', runner.lastRecordMs)
      ..add('gpu', runner.lastGpuOwnMs);
    if (runner.timedParts.isNotEmpty) {
      final sections = _r.gpuSections;
      for (var i = 0; i < sections.length; i++) {
        _profiler.add(sections[i], runner.lastPartGpuMs[i]);
        _parts[i] += runner.lastPartGpuMs[i];
      }
    }
    _build += _r.lastBuildMs;
    _pointDraws += _r.builder.pointShadowDraws;
    _record += runner.lastRecordMs;
    _gpu += runner.lastGpuOwnMs;
    // alloc: the end of the run, once.
    if (t >= widget.seconds) _finish();
  }

  /// The camera on an ellipse inside the paths of the lights, a little
  /// above the low lights, looking along the path.
  void _place(double t) {
    final l = _lights;
    final a = t * 2 * math.pi / 40;
    final rx = l.radiusX * 0.8, rz = l.radiusZ * 0.5;
    _fly.position.setValues(
      l.center.x + rx * libm.cos(a),
      l.lowY + 0.35,
      l.center.z + rz * libm.sin(a),
    );
    // The tangent of the ellipse.
    _fly
      ..yaw = libm.atan2(rx * libm.sin(a), -rz * libm.cos(a))
      ..pitch = 0.05;
  }

  // alloc-cold: once, at the end of the run.
  Future<void> _finish() async {
    _done = true;
    _ticker.stop();
    await _profiler.close();
    final n = math.min(_frames - 1, _intervals.length);
    final sorted = Float64List.fromList(_intervals.sublist(0, n))..sort();
    double at(double q) => n == 0 ? 0 : sorted[((n - 1) * q).round()];
    final frames = _frames.toDouble();
    stdout.writeln(
      'PERF $n frames at ${perfWidth}x$perfHeight, interval p50 '
      '${at(0.5).toStringAsFixed(2)} ms, p95 ${at(0.95).toStringAsFixed(2)} '
      'ms, p99 ${at(0.99).toStringAsFixed(2)} ms, max '
      '${at(1).toStringAsFixed(2)} ms; mean build '
      '${(_build / frames).toStringAsFixed(2)} ms, record '
      '${(_record / frames).toStringAsFixed(2)} ms, GPU '
      '${(_gpu / frames).toStringAsFixed(2)} ms; ${_r.builder.drawCount} '
      'draws and ${(_pointDraws / frames).round()} of point shadows; log in '
      '${_profiler.dir}',
    );
    if (_r.timed) {
      final labels = _r.builder.partLabels;
      stdout.writeln(
        'PERF parts ${[for (var i = 0; i < labels.length; i++) '${labels[i]} ${(_parts[i] / frames).toStringAsFixed(2)} ms'].join(', ')}',
      );
    }
    exit(0);
  }

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: FramePainter(_r, _repaint), size: Size.infinite);
}

final _noPad = PadState();
