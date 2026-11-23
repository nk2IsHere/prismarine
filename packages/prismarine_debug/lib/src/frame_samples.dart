// The frame graph's model: per-frame timings folded into the graph's groups
// and the ring of the last frames.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Color, Paint;

import 'package:flutter/foundation.dart';
import 'package:prismarine_kept/prismarine_kept.dart';

import 'profiler.dart';

/// A group of the frame graph's stacked bars: its label and its colour.
class FrameGroupStyle {
  FrameGroupStyle(this.label, this.color);
  final String label;
  final Color color;

  /// The fill of the group's bars.
  late final Paint paint = Paint()..color = color;
}

/// One frame's time per group (ms), its raster time, its wall gap to the
/// next frame and the timed sections it was made of (the graph's hover).
/// A subclass puts each section's time into its groups in [sort].
class FrameSample {
  FrameSample(int groups) : ms = Float64List(groups);

  /// Per group, by its index in [FrameSamples.groups].
  final Float64List ms;
  double raster = 0;
  double dt = 0;

  /// The wall time to the next frame's tick (ms; 0 until it starts).
  double gap = 0;

  /// The UI tick's wall time (ms).
  double tick = 0;

  /// Every section as reported, in order: its name and ms at the same
  /// place, [sectionCount] of them (perf: a record per section a frame).
  final sectionNames = KeptList<String>();
  var sectionMs = Float64List(64);
  int get sectionCount => sectionNames.length;

  /// The sample for another frame (FrameSamples reuses the one its history
  /// drops).
  @mustCallSuper
  void reset() {
    ms.fillRange(0, ms.length, 0);
    raster = dt = gap = tick = 0;
    sectionNames.clear();
  }

  void add(String section, double v) {
    final n = sectionNames.length;
    if (n == sectionMs.length) {
      sectionMs = Float64List(n * 2)..setRange(0, n, sectionMs);
    }
    sectionMs[n] = v;
    sectionNames.add(section);
    sort(section, v);
  }

  /// Adds [v] ms of [section] to the groups it belongs to.
  @protected
  void sort(String section, double v) {}

  /// Closes the frame once the next one starts: [gap] its wall time,
  /// [untimed] the time the event loop was held outside our timed work
  /// ([LoopMonitor]); [inline] when the game ran on the UI isolate (its
  /// phases are inside the tick).
  @mustCallSuper
  void finish({
    required double gap,
    required double untimed,
    bool inline = false,
  }) {
    this.gap = gap;
  }

  double get total {
    var sum = 0.0;
    for (var i = 0; i < ms.length; i++) {
      sum += ms[i];
    }
    return sum + raster;
  }
}

/// The last frames' samples, drawn by the frame graph in [groups]. A
/// subclass makes its samples in [newSample].
abstract class FrameSamples {
  FrameSamples(this.groups);

  /// The graph's stacked groups, bottom to top.
  final List<FrameGroupStyle> groups;

  /// `--profile`'s recorder (null without it).
  FrameProfiler? profiler;

  static const _frames = 240;
  final frames = ListQueue<FrameSample>();

  /// Bumped when a frame closes: the frame graph repaints on it (every
  /// frame) while the rest of the panel rebuilds at most every 250 ms.
  final graph = ValueNotifier<int>(0);

  /// Whether the game runs on the UI isolate (`--sim=inline`).
  bool simInline = false;

  FrameSample? _open, _spare;
  int _openUs = 0;
  final _wall = Stopwatch()..start();

  /// A sample for a new frame, with [groups]' length of times.
  FrameSample newSample();

  /// Starts a frame: the previous one closes with its wall gap and lag.
  FrameSample beginFrame() {
    final now = _wall.elapsedMicroseconds;
    if (_open case final f?) {
      f.finish(
        gap: (now - _openUs) / 1000,
        untimed: _loop?.take().$2 ?? 0,
        inline: simInline,
      );
      _push(f);
    }
    _openUs = now;
    // The sample the history dropped again, while the panel is hidden (it
    // may hold a hovered one; perf: a sample and its lists per frame).
    final spare = _spare;
    _spare = null;
    return _open = spare == null || _loop != null
        ? newSample()
        : (spare..reset());
  }

  /// The frame's tick ended: it closes now, or with [keepOpen] (real time)
  /// takes its paint's sections until the next [beginFrame] closes it.
  void endFrame(FrameSample f, {double raster = 0, bool keepOpen = false}) {
    f.raster = raster;
    if (!keepOpen || !identical(f, _open)) {
      _push(f);
      if (identical(f, _open)) _open = null;
    }
  }

  /// The frame sections arrive in until the next tick (the paint's).
  FrameSample? get openFrame => _open;

  void _push(FrameSample f) {
    frames.addLast(f);
    while (frames.length > _frames) {
      _spare = frames.removeFirst();
    }
    graph.value++;
  }

  // The event loop held outside our timed work (as the profiler's), only
  // while the panel shows.
  LoopMonitor? _loop;

  void measureLag(bool on) {
    if (on == (_loop != null)) return;
    _loop?.cancel();
    _loop = on ? LoopMonitor() : null;
  }

  /// Frames per second over the last 60 frames' wall time.
  double get fps {
    final f = frames.toList();
    final last = f.skip(math.max(0, f.length - 60)).where((s) => s.dt > 0);
    if (last.isEmpty) return 0;
    final mean = last.map((s) => s.dt).reduce((a, b) => a + b) / last.length;
    return mean > 0 ? 1 / mean : 0;
  }

  /// The mean ms of group [g] over the last 60 frames.
  double meanMs(int g) {
    final f = frames.toList();
    final last = f.skip(math.max(0, f.length - 60));
    if (last.isEmpty) return 0;
    return last.map((s) => s.ms[g]).reduce((a, b) => a + b) / last.length;
  }

  /// The mean raster ms over the last 60 frames.
  double get meanRaster {
    final f = frames.toList();
    final last = f.skip(math.max(0, f.length - 60));
    if (last.isEmpty) return 0;
    return last.map((s) => s.raster).reduce((a, b) => a + b) / last.length;
  }
}
