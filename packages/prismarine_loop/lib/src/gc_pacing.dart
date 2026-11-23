import 'dart:ui' show DartPerformanceMode, PlatformDispatcher;

/// GC pacing: the Dart VM's collections at its normal thresholds, none
/// started by the engine's idle notification, and where the engine has the
/// call ([collect]) at the frame's idle point ([idlePoint]); collections
/// never change what the game computes.
///
/// After each frame the engine lets the VM work until the next one; with
/// this game's large heap that meant a full concurrent mark every ~0.6 s.
/// The engine skips that notification in latency mode, so the mode is
/// latency from [endFrame] to [beginFrame] and balanced in the frame. GPU
/// memory awaiting finalization isn't counted by the VM: when [pressure]
/// grows by [budget] the frames stay balanced through the notification
/// until it falls back by half or [reliefFrames] pass.
class GcPacing {
  GcPacing({
    required this.enabled,
    this.pressure,
    this.budget = 256 << 20,
    this.reliefFrames = 90,
    this.collect,
    this.busy,
    this.frameMicros = 16667,
    this.idleMinBytes = 16 << 20,
    this.idleMaxBytes = 64 << 20,
    this.onIdle,
    this.oldSpace,
    this.heap,
    this.compactGrowthBytes,
    this.onCompact,
  });

  final bool enabled;

  /// GPU bytes awaiting finalization or live (flutter_gpu GpuMemory, G8).
  final int Function()? pressure;
  final int budget;
  final int reliefFrames;

  /// The VM's collections at an idle point (flutter_gpu `mcsmGcIdle`: the
  /// time left in microseconds, the least and the most new-space bytes);
  /// what ran (0: nothing). Null on an engine without it.
  final int Function(int budgetMicros, int minBytes, int maxBytes)? collect;

  /// Whether a picture is on its way (its plan asked for and not recorded):
  /// the frame's end is then no idle point, the record's end is.
  final bool Function()? busy;

  /// The display's frame interval.
  int frameMicros;
  final int idleMinBytes;
  final int idleMaxBytes;

  /// An idle point's collection: what ran, its time and the time it was
  /// given, in ms (the profile).
  final void Function(int ran, double ms, double budgetMs)? onIdle;

  /// Old-space work now (flutter_gpu `mcsmOldSpace`: 2 compacts); null on
  /// an engine without it.
  final int Function(int request)? oldSpace;

  /// The heap's figures (flutter_gpu `mcsmHeap`: 0 old space used, 1 its
  /// capacity, in bytes); null on an engine without it.
  final int Function(int which)? heap;

  /// How much the old space's capacity grows past its size after the last
  /// compaction (0 before the first) before a scene switch's hold compacts
  /// it; null: never.
  final int? compactGrowthBytes;

  /// A compaction: its time in ms and the old space's capacity before and
  /// after, in bytes (the log and the profile).
  final void Function(double ms, int capacityBefore, int capacityAfter)?
  onCompact;

  final _clock = Stopwatch()..start();
  int _frameStartUs = 0;

  /// Compactions run (diagnostics, the run log).
  int compactions = 0;

  /// The old space's capacity after the last compaction.
  int _compacted = 0;

  /// When the last mark was started ahead of a switch ([premark]), on
  /// [_clock]; null: none since the last compaction.
  int? _premarkUs;

  /// Marks started ahead of a switch (diagnostics, the run log).
  int premarks = 0;

  /// Seconds since the mark [switchHold]'s last compaction found started
  /// ahead; null: it marked in the hold.
  double? lastPremarkAge;

  /// A scene is coming (added, or about to open): when its switch's hold
  /// will compact ([switchHold]'s growth reached), the old space's mark
  /// starts now, concurrently, on the VM's helper threads; finished, it
  /// waits for the hold (up to 30 s; dart/0003), whose stop-the-world pause
  /// is then the slide alone (Ep205's route on the Mac: the boot's 1.7 →
  /// 0.5 s, the others 1.1–2.2 s either way: the slide of ~2 GB, in swap,
  /// is most of it). At most one every 10 s.
  void premark() {
    final oldSpace = this.oldSpace, heap = this.heap;
    final growth = compactGrowthBytes;
    if (oldSpace == null || heap == null || growth == null) return;
    final capacity = heap(1);
    if (capacity < 0 || capacity - _compacted < growth) return;
    final now = _clock.elapsedMicroseconds;
    if (_premarkUs case final at? when now - at < 10000000) return;
    _premarkUs = now;
    if (oldSpace(1) & 1 != 0) premarks++;
  }

  /// A scene switch's hold: the new scene's first picture is not painted
  /// yet and the screen holds the last one, as the exe's blocking scene
  /// load holds it. The VM's old space gives pages back only when
  /// compacted (its sweeps leave the pages fragmented: over Ep205's
  /// playtest route its capacity grew 1.6 → 3.4 GB for 1.25 → 1.95 GB
  /// live), so once its capacity grew [compactGrowthBytes] past what the
  /// last compaction left, it is compacted here, every isolate of the
  /// group stopped; at a switch the closed scene's objects are garbage too.
  /// Its use is no measure of what is free: it counts what was allocated
  /// since the last mark, dead or not. Whether the game's state changes:
  /// never (collections move objects, not values).
  void switchHold() {
    final oldSpace = this.oldSpace, heap = this.heap;
    final growth = compactGrowthBytes;
    if (oldSpace == null || heap == null || growth == null) return;
    final capacity = heap(1);
    if (capacity < 0 || capacity - _compacted < growth) return;
    final t0 = _clock.elapsedMicroseconds;
    if (oldSpace(2) & 2 == 0) return;
    // A mark older than 30 s was finalized as a sweep meanwhile.
    final at = _premarkUs;
    lastPremarkAge = at != null && t0 - at < 30000000 ? (t0 - at) / 1e6 : null;
    _premarkUs = null;
    compactions++;
    _compacted = heap(1);
    onCompact?.call(
      (_clock.elapsedMicroseconds - t0) / 1000,
      capacity,
      _compacted,
    );
  }

  /// Idle points that collected (diagnostics, the run log).
  int idleCollections = 0;

  /// The frame's idle point: its picture has just been recorded, or it
  /// ended with no picture on its way, so the UI isolate (and, when the
  /// frame fits its interval, the sim and the build) has time until the
  /// next frame is due. A young collection runs when new space holds
  /// [idleMinBytes] and the VM expects it to fit that time, or holds
  /// [idleMaxBytes] whatever the time: small ones where a pause costs
  /// least, so new space never fills inside a frame (a collection there
  /// stops the three isolates wherever they are; with little garbage they
  /// came seconds apart and tens of ms long). A finished old-space mark is
  /// finalized here too.
  void idlePoint() {
    final collect = this.collect;
    if (!enabled || collect == null) return;
    final now = _clock.elapsedMicroseconds;
    final left = _frameStartUs + frameMicros - now;
    final budget = left > 0 ? left : 0;
    final ran = collect(budget, idleMinBytes, idleMaxBytes);
    if (ran == 0) return;
    idleCollections++;
    onIdle?.call(ran, (_clock.elapsedMicroseconds - now) / 1000, budget / 1000);
  }

  bool _latency = false;
  int? _floor;
  int _relief = 0;

  /// Whether the frames now let the idle policy run (diagnostics).
  bool get relieving => _relief > 0;

  /// How many reliefs ran (diagnostics, the run log).
  int reliefs = 0;

  /// A frame starts: balanced (the VM's threshold check runs now).
  void beginFrame() {
    _frameStartUs = _clock.elapsedMicroseconds;
    if (!enabled || !_latency) return;
    _latency = false;
    PlatformDispatcher.instance.requestDartPerformanceMode(
      DartPerformanceMode.balanced,
    );
  }

  /// The frame's Dart work is done: latency until the next [beginFrame], so
  /// the engine's idle notification after this frame doesn't reach the VM.
  void endFrame() {
    if (enabled && !(busy?.call() ?? false)) idlePoint();
    if (!enabled || _latency) return;
    if (pressure case final p?) {
      final now = p();
      final floor = _floor ??= now;
      if (_relief > 0) {
        if (now <= floor + budget ~/ 2 || --_relief == 0) {
          _relief = 0;
          _floor = now;
        } else {
          return; // stays balanced: the idle notification reaches the VM
        }
      } else if (now > floor + budget) {
        _relief = reliefFrames;
        reliefs++;
        return;
      } else if (now < floor) {
        _floor = now;
      }
    }
    _latency = true;
    PlatformDispatcher.instance.requestDartPerformanceMode(
      DartPerformanceMode.latency,
    );
  }

  /// Back to the VM's own policy.
  void stop() => beginFrame();
}
