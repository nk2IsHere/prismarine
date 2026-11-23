// The model of the frame graph. It folds per-frame timings into the groups
// of the graph and keeps the ring of the last frames.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Color, Paint;

import 'package:flutter/foundation.dart';
import 'package:prismarine_kept/prismarine_kept.dart';

import 'profiler.dart';

/// A group of the stacked bars of the frame graph, with its label and its
/// colour.
class FrameGroupStyle {
  FrameGroupStyle(this.label, this.color);
  final String label;
  final Color color;

  /// The fill of the bars of the group.
  late final Paint paint = Paint()..color = color;
}

/// The time of one frame per group in ms, its raster time, its wall gap to
/// the next frame and its timed sections. A subclass puts the time of each
/// section into its groups in [sort].
class FrameSample {
  FrameSample(int groups) : ms = Float64List(groups);

  /// The ms of each group, by its index in [FrameSamples.groups].
  final Float64List ms;
  double raster = 0;
  double dt = 0;

  /// The wall time in ms to the tick of the next frame, 0 until it starts.
  double gap = 0;

  /// The wall time of the UI tick in ms.
  double tick = 0;

  /// Every section as reported, in order. The name and the ms of a section
  /// are at the same index of the two lists, [sectionCount] of them.
  final sectionNames = KeptList<String>();
  var sectionMs = Float64List(64);
  int get sectionCount => sectionNames.length;

  /// Resets the sample for another frame.
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

  /// Adds [v] ms of [section] to the groups of the section.
  @protected
  void sort(String section, double v) {}

  /// Closes the frame once the next one starts. [gap] is its wall time.
  /// [untimed] is the time that the event loop was held outside the timed
  /// work, from [LoopMonitor]. [inline] is true when the game ran on the UI
  /// isolate, with its phases inside the tick.
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

/// The samples of the last frames, drawn by the frame graph in [groups]. A
/// subclass makes its samples in [newSample].
abstract class FrameSamples {
  FrameSamples(this.groups);

  /// The stacked groups of the graph, bottom to top.
  final List<FrameGroupStyle> groups;

  /// The profiler that receives the timings of the panel, or null.
  FrameProfiler? profiler;

  static const _frames = 240;
  final frames = ListQueue<FrameSample>();

  /// Changes when a frame closes. The frame graph repaints on it every frame.
  final graph = ValueNotifier<int>(0);

  /// True when the game runs on the UI isolate.
  bool simInline = false;

  FrameSample? _open, _spare;
  int _openUs = 0;
  final _wall = Stopwatch()..start();

  /// Returns a sample for a new frame with one time per group.
  FrameSample newSample();

  /// Starts a frame. The previous frame closes with its wall gap and lag.
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
    // The sample that the history dropped is used again while the panel is
    // hidden. A shown panel may hold it as the hovered frame.
    final spare = _spare;
    _spare = null;
    return _open = spare == null || _loop != null
        ? newSample()
        : (spare..reset());
  }

  /// Ends the tick of [f] with its [raster] time. The frame closes now. With
  /// [keepOpen] it takes the sections of its paint until the next
  /// [beginFrame] closes it.
  void endFrame(FrameSample f, {double raster = 0, bool keepOpen = false}) {
    f.raster = raster;
    if (!keepOpen || !identical(f, _open)) {
      _push(f);
      if (identical(f, _open)) _open = null;
    }
  }

  /// The frame that receives the sections of the paint until the next tick.
  FrameSample? get openFrame => _open;

  void _push(FrameSample f) {
    frames.addLast(f);
    while (frames.length > _frames) {
      _spare = frames.removeFirst();
    }
    graph.value++;
  }

  // Measures the event loop held outside the timed work, only while the
  // panel shows.
  LoopMonitor? _loop;

  void measureLag(bool on) {
    if (on == (_loop != null)) return;
    _loop?.cancel();
    _loop = on ? LoopMonitor() : null;
  }

  /// Frames per second over the wall time of the last 60 frames.
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
