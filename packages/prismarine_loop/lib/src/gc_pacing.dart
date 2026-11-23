import 'dart:ui' show DartPerformanceMode, PlatformDispatcher;

/// GC pacing. The Dart VM collects at its normal thresholds and not on the
/// idle notification of the engine. An engine with the call [collect] also
/// collects at the idle point of the frame ([idlePoint]). Collections do not
/// change what the game computes.
///
/// The engine skips its idle notification after a frame in latency mode. The
/// mode is latency from [endFrame] to [beginFrame] and balanced in the frame.
/// The VM does not count GPU memory that awaits finalization. The frames stay
/// balanced through the notification after [pressure] grows by [budget], until
/// it falls back by half or [reliefFrames] pass.
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

  /// The GPU bytes that are live or await finalization (flutter_gpu
  /// GpuMemory, G8).
  final int Function()? pressure;
  final int budget;
  final int reliefFrames;

  /// Runs the collections of the VM at an idle point with the GC idle call
  /// of flutter_gpu. It takes the time left in microseconds and the least
  /// and the most new-space bytes. Returns the work that ran, 0 for none.
  /// Null on an engine without the call.
  final int Function(int budgetMicros, int minBytes, int maxBytes)? collect;

  /// Returns true while a picture is on its way, with its plan requested and
  /// not recorded. The idle point is then the end of the record and not the
  /// end of the frame.
  final bool Function()? busy;

  /// The frame interval of the display.
  int frameMicros;
  final int idleMinBytes;
  final int idleMaxBytes;

  /// Receives the collection of an idle point with the work that ran, its
  /// time and the time it was given, in ms.
  final void Function(int ran, double ms, double budgetMs)? onIdle;

  /// Runs old-space work now through the old-space call of flutter_gpu,
  /// where the request 2 compacts. Null on an engine without the call.
  final int Function(int request)? oldSpace;

  /// Returns a figure of the heap in bytes through the heap call of
  /// flutter_gpu. 0 selects the old space used and 1 its capacity. Null on an
  /// engine without the call.
  final int Function(int which)? heap;

  /// The growth of the capacity of the old space past its size after the
  /// last compaction, 0 before the first, at which the hold of a scene
  /// switch compacts it. Null turns compaction off.
  final int? compactGrowthBytes;

  /// Receives each compaction with its time in ms and the capacity of the
  /// old space before and after it, in bytes.
  final void Function(double ms, int capacityBefore, int capacityAfter)?
  onCompact;

  final _clock = Stopwatch()..start();
  int _frameStartUs = 0;

  /// The number of compactions run.
  int compactions = 0;

  /// The capacity of the old space after the last compaction.
  int _compacted = 0;

  /// The time on [_clock] of the last mark started ahead of a switch by
  /// [premark]. Null when none started since the last compaction.
  int? _premarkUs;

  /// The number of marks started ahead of a switch.
  int premarks = 0;

  /// The age in seconds of the early mark that the last compaction of
  /// [switchHold] found. Null when the hold made its own mark.
  double? lastPremarkAge;

  /// Call it when a scene is added or about to open. The mark of the old space
  /// starts now on the helper threads of the VM if the hold of its switch will
  /// compact. A finished mark waits up to 30 s for the hold (dart/0003). The
  /// stop-the-world pause of the hold is then the slide alone. Starts at most
  /// one mark every 10 s.
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

  /// Call it in the hold of a scene switch, while the first picture of the
  /// new scene is not painted yet and the screen holds the last one. The old
  /// space of the VM gives pages back only when it is compacted. Once its
  /// capacity grew [compactGrowthBytes] past the size after the last
  /// compaction, it is compacted here with every isolate of the group
  /// stopped. The used size of the old space does not measure free memory,
  /// since it counts every allocation since the last mark, dead or not.
  /// Collections move objects and do not change the state of the game.
  void switchHold() {
    final oldSpace = this.oldSpace, heap = this.heap;
    final growth = compactGrowthBytes;
    if (oldSpace == null || heap == null || growth == null) return;
    final capacity = heap(1);
    if (capacity < 0 || capacity - _compacted < growth) return;
    final t0 = _clock.elapsedMicroseconds;
    if (oldSpace(2) & 2 == 0) return;
    // A mark older than 30 s was finalized as a sweep in the meantime.
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

  /// The number of idle points that collected.
  int idleCollections = 0;

  /// Call it at the idle point of the frame, when its picture has just been
  /// recorded or the frame ended with no picture on its way. The UI isolate
  /// then has time until the next frame is due. The other isolates have it too
  /// when the frame fits its interval. A young collection runs when new space
  /// holds [idleMinBytes] and the VM expects it to fit that time, or when new
  /// space holds [idleMaxBytes] at any time. New space then does not fill
  /// inside a frame, where a collection stops every isolate wherever it is. A
  /// finished old-space mark is finalized here too.
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

  /// True when the frames now let the idle policy run.
  bool get relieving => _relief > 0;

  /// The number of reliefs that ran.
  int reliefs = 0;

  /// Starts a frame in balanced mode. The threshold check of the VM runs now.
  void beginFrame() {
    _frameStartUs = _clock.elapsedMicroseconds;
    if (!enabled || !_latency) return;
    _latency = false;
    PlatformDispatcher.instance.requestDartPerformanceMode(
      DartPerformanceMode.balanced,
    );
  }

  /// Ends the Dart work of the frame. The mode is latency until the next
  /// [beginFrame], which keeps the idle notification of the engine after
  /// this frame from the VM.
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
          return; // balanced, with the idle notification for the VM
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

  /// Returns to the policy of the VM.
  void stop() => beginFrame();
}
