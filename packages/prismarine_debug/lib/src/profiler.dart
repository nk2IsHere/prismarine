// The player's per-frame profiler: `--profile=<dir>` writes frames.jsonl (one
// object per frame: t, dt, rss every 30 frames, each timed section in ms),
// timings.jsonl (Flutter FrameTiming), and, on close,
// summary.txt (p50/p95/max per section over the acceptance stretches).
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show FrameTiming;

import 'package:flutter_gpu/gpu.dart' show GpuMemory;

import 'package:prismarine_loop/prismarine_loop.dart';

class FrameProfiler {
  /// A profile into [dir] whose summary covers each of [windows], a name
  /// with the first and the end time of its stretch.
  FrameProfiler(this.dir, {this.windows = const [('all', 0.0, 1e9)]})
    : _frames = JsonLineWriter('${_made(dir)}/frames.jsonl', buffer: 1 << 15),
      _timings = JsonLineWriter('$dir/timings.jsonl', buffer: 1 << 13),
      _stalls = File('$dir/stalls.jsonl').openWrite();

  final List<(String, double, double)> windows;

  /// A first-use pipeline compile of [what] that took [us]: added to this
  /// frame's `load.pipe.<what>` and logged with [origin], where the pipeline
  /// was built.
  void stall(String what, int us, String origin) {
    add('load.pipe.$what', us / 1000);
    if (_closed) return;
    _stalls.writeln(
      jsonEncode({
        't': _open ? _t : null,
        'what': what,
        'ms': us / 1000,
        'origin': origin,
      }),
    );
  }

  /// `loop.lag` (the longest the event loop was held, our sections
  /// included) and `loop.untimed` (held outside them) per frame.
  final _loop = LoopMonitor();

  static String _made(String dir) {
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  final String dir;
  final JsonLineWriter _frames, _timings;
  final IOSink _stalls;

  /// The render isolate's audio trace (blocks, loads; output.dart).
  String get audioTrace => '$dir/audio.jsonl';

  // A frame is a row of numbers by column (a section's name, numbered at
  // its first use), written as a JSON line from kept bytes; every row is
  // kept as (column, value) pairs in typed lists for the summary (perf: a
  // map, its boxed numbers and a JSON string per frame, the maps kept for
  // the run).
  final _cols = <String, int>{};
  final _names = <String>[];
  var _row = Float64List(64);
  var _has = Uint8List(64);

  /// The columns set this frame, in the order first set (the line's).
  var _touched = Int32List(64);
  int _nTouched = 0;
  bool _open = false;
  double _t = 0;
  int _n = 0;
  bool _closed = false;

  var _allCols = Int32List(1 << 14);
  var _allVals = Float64List(1 << 14);
  int _allN = 0;
  var _ends = Int32List(1 << 10);
  int _nFrames = 0;

  late final int _cT = _col('t'), _cDt = _col('dt');
  late final int _cLag = _col('loop.lag'), _cUntimed = _col('loop.untimed');
  late final int _cWall = _col('wall'), _cRss = _col('rss');
  late final int _cFootprint = _col('mem.footprint');
  final _gpuCols = <String, int>{};

  int _col(String name) => _cols[name] ?? _newCol(name);

  int _newCol(String name) {
    final c = _names.length;
    _names.add(name);
    _cols[name] = c;
    if (c == _row.length) {
      _row = Float64List(c * 2)..setRange(0, c, _row);
      _has = Uint8List(c * 2)..setRange(0, c, _has);
      _touched = Int32List(c * 2)..setRange(0, _nTouched, _touched);
    }
    return c;
  }

  void _put(int c, double v) {
    if (_has[c] == 0) {
      _has[c] = 1;
      _touched[_nTouched++] = c;
      _row[c] = v;
    } else {
      _row[c] = v;
    }
  }

  /// Starts a frame (the previous one is written).
  void beginFrame({required double t, required double dt}) {
    _flush();
    final (lag, untimed) = _loop.take();
    _open = true;
    _t = t;
    _put(_cT, t);
    _put(_cDt, dt);
    _put(_cLag, lag);
    _put(_cUntimed, untimed);
    _put(_cWall, DateTime.now().microsecondsSinceEpoch.toDouble());
    if (_n++ % 30 == 0) {
      _put(_cRss, ProcessInfo.currentRss.toDouble());
      // What Activity Monitor shows (compressed and swapped pages and the
      // GPU's allocations included), and the GPU memory made through
      // Flutter GPU by kind (MB).
      if (physFootprint() case final f?) _put(_cFootprint, f / 1048576);
      GpuMemory.bytes.forEach(_gpu_);
    }
  }

  late final _gpu_ = _gpu;

  void _gpu(String kind, int bytes) =>
      _put(_gpuCols[kind] ??= _col('mem.gpu.$kind'), bytes / 1048576);

  /// Adds [ms] to this frame's [section] (sections repeat within a frame).
  void add(String section, double ms) {
    if (!_open) return;
    final c = _col(section);
    if (_has[c] == 0) {
      _put(c, ms);
    } else {
      _row[c] += ms;
    }
  }

  /// Sets this frame's [key].
  void set(String key, double value) {
    if (_open) _put(_col(key), value);
  }

  void timings(List<FrameTiming> ts) {
    if (_closed) return;
    for (var i = 0; i < ts.length; i++) {
      final t = ts[i];
      _timings
        ..begin()
        ..key('n')
        ..integer(t.frameNumber)
        ..key('build')
        ..number(t.buildDuration.inMicroseconds / 1000, 3)
        ..key('raster')
        ..number(t.rasterDuration.inMicroseconds / 1000, 3)
        ..key('total')
        ..number(t.totalSpan.inMicroseconds / 1000, 3)
        ..end();
    }
  }

  void _flush() {
    if (!_open || _closed) return;
    final w = _frames..begin();
    if (_allN + _nTouched > _allCols.length) {
      final size = _allCols.length * 2;
      _allCols = Int32List(size)..setRange(0, _allN, _allCols);
      _allVals = Float64List(size)..setRange(0, _allN, _allVals);
    }
    for (var i = 0; i < _nTouched; i++) {
      final c = _touched[i];
      final v = _row[c];
      w.key(_names[c]);
      // Whole numbers of the clock and the memory as integers.
      if (c == _cWall || c == _cRss) {
        w.integer(v.toInt());
      } else {
        w.number(v);
      }
      _allCols[_allN] = c;
      _allVals[_allN++] = v;
      _has[c] = 0;
    }
    w.end();
    if (_nFrames == _ends.length) {
      _ends = Int32List(_nFrames * 2)..setRange(0, _nFrames, _ends);
    }
    _ends[_nFrames++] = _allN;
    _nTouched = 0;
    _open = false;
  }

  /// Every frame as a map, for [summarize] (made once, at the end).
  List<Map<String, Object?>> _maps() {
    final out = <Map<String, Object?>>[];
    var at = 0;
    for (var f = 0; f < _nFrames; f++) {
      final m = <String, Object?>{};
      for (; at < _ends[f]; at++) {
        m[_names[_allCols[at]]] = _allVals[at];
      }
      out.add(m);
    }
    return out;
  }

  Future<void> close() async {
    if (_closed) return;
    _flush();
    _closed = true;
    _loop.cancel();
    _frames.close();
    _timings.close();
    await _stalls.close();
    File('$dir/summary.txt').writeAsStringSync(summarize(_maps(), windows));
  }
}

/// The UI isolate's own timed work (µs so far): the tick less its waits for
/// the sim, the paint's sections and the panel's graph. [LoopMonitor] takes
/// it out of the event loop's lateness.
abstract final class UiWork {
  static int micros = 0;

  /// Of [micros], the paint's and the graph's: they can run while the tick
  /// awaits the sim (a Flutter frame between the request and the reply).
  static int paintMicros = 0;

  static void add(double ms, {bool paint = false}) {
    final us = (ms * 1000).round();
    micros += us;
    if (paint) paintMicros += us;
  }
}

/// The event loop's lateness, measured by a 1 ms timer: [take] gives, since
/// the last take, the longest the loop was held (`loop.lag`: our own
/// sections included, so it is about the longest synchronous section) and
/// the time it was held outside our timed UI work ([UiWork]): a GC pause of
/// the isolate group (the sim's allocation stops this isolate too), Flutter's
/// own build, layout and compositing (the panel's rebuilds), timers and port
/// messages, or the thread not scheduled by the OS while work was due.
/// Lateness under 0.5 ms a tick is timer jitter, not counted.
class LoopMonitor {
  LoopMonitor() {
    _clock.start();
    _own = UiWork.micros;
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = _clock.elapsedMicroseconds;
      final late = now - _last - 1000;
      _last = now;
      final own = UiWork.micros - _own;
      _own = UiWork.micros;
      if (late > _lagMax) _lagMax = late;
      final untimed = late - own;
      if (untimed > 500) _untimed += untimed;
    });
  }

  final _clock = Stopwatch();
  int _last = 0, _own = 0, _lagMax = 0, _untimed = 0;
  Timer? _timer;

  /// (lag, untimed) in ms since the last take.
  (double, double) take() {
    final r = (_lagMax / 1000, _untimed / 1000);
    _lagMax = 0;
    _untimed = 0;
    return r;
  }

  void cancel() => _timer?.cancel();
}

double _pct(List<double> v, double p) =>
    v.isEmpty ? 0 : v[((v.length - 1) * p).round().clamp(0, v.length - 1)];

/// Per window: the frame count, then each numeric section's p50/p95/max.
String summarize(
  List<Map<String, Object?>> frames,
  List<(String, double, double)> windows,
) {
  final out = StringBuffer();
  for (final (name, a, b) in windows) {
    final sel = [
      for (final f in frames)
        if ((f['t'] as num) >= a && (f['t'] as num) < b) f,
    ];
    if (sel.isEmpty) continue;
    out.writeln('== $name: ${sel.length} frames');
    final gaps = [
      for (final f in sel)
        if (f['gap'] case final num g) g.toDouble(),
    ];
    if (gaps.isNotEmpty) {
      out.writeln(
        'gaps > 20 ms: ${gaps.where((g) => g > 20).length}, '
        '> 33 ms: ${gaps.where((g) => g > 33).length}, '
        '> 50 ms: ${gaps.where((g) => g > 50).length}, '
        '> 100 ms: ${gaps.where((g) => g > 100).length}',
      );
    }
    final keys = {
      for (final f in sel)
        for (final MapEntry(:key, :value) in f.entries)
          if (value is num && key != 't' && key != 'rss' && key != 'wall') key,
    }.toList()..sort();
    for (final k in keys) {
      final v = [for (final f in sel) ((f[k] as num?) ?? 0).toDouble()]..sort();
      out.writeln(
        '${k.padRight(24)} p50 ${_pct(v, .5).toStringAsFixed(2).padLeft(7)}'
        '  p95 ${_pct(v, .95).toStringAsFixed(2).padLeft(7)}'
        '  max ${v.last.toStringAsFixed(2).padLeft(8)}',
      );
    }
  }
  return out.toString();
}

/// The process's physical footprint in bytes (`ri_phys_footprint` of
/// `proc_pid_rusage`, what Activity Monitor's Memory column shows), or null
/// off macOS.
int? physFootprint() {
  final f = _rusage;
  if (f == null) return null;
  final buf = _rusageBuf ??= _malloc(512);
  if (f(_getpid!(), 2, buf) != 0) return null;
  // rusage_info_v2: uuid[16], then u64 user_time, system_time,
  // pkg_idle_wkups, interrupt_wkups, pageins, wired_size, resident_size,
  // phys_footprint.
  return Pointer<Uint64>.fromAddress(buf.address + 16 + 7 * 8).value;
}

Pointer<Void>? _rusageBuf;
final _libc = Platform.isMacOS ? DynamicLibrary.process() : null;
final int Function(int, int, Pointer<Void>)? _rusage = _libc
    ?.lookupFunction<
      Int32 Function(Int32, Int32, Pointer<Void>),
      int Function(int, int, Pointer<Void>)
    >('proc_pid_rusage');
final int Function()? _getpid = _libc
    ?.lookupFunction<Int32 Function(), int Function()>('getpid');
final Pointer<Void> Function(int) _malloc = _libc!
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
