// Frames in flight on macOS: the player's frames wait for the GPU.
//
// The raster thread writes each composite's vertices and uniforms into a
// ring of four arenas (Impeller's HostBuffer) and reuses an arena four
// frames later without waiting for the GPU. On iOS the CAMetalLayer's few
// drawables hold it back; on macOS nothing does, so when the 3D scene's GPU
// work falls behind, composites queue more than four deep and one reads a
// later one's arena: streaked triangles, garbled text, a wrong-coloured
// panel for a frame or a run of frames.
//
// The limiter bounds that queue as the drawables do on iOS: each frame it
// commits an empty marker command buffer on the engine's own Metal queue
// and waits (polling, at most 250 ms) until the marker of two frames before
// has completed. With Flutter's two-frame pipeline that is composite k − 4,
// whose arena frame k reuses; the wait is only the GPU backlog beyond it.
//
// Plain dart:ffi on the Objective-C runtime (objc.dart): no engine change.
// `MCSM_GPU_FRAME_GATE=off`: no limiter (to show the race).
import 'dart:ffi';
import 'dart:io';

import 'objc.dart';

final _msgWait = objcLib
    .lookupFunction<
      Void Function(ObjcId, ObjcId),
      void Function(ObjcId, ObjcId)
    >('objc_msgSend');
final _msgStatus = objcLib
    .lookupFunction<
      IntPtr Function(ObjcId, ObjcId),
      int Function(ObjcId, ObjcId)
    >('objc_msgSend');
final _usleep = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Uint32), int Function(int)>('usleep');
final _msgResponds = objcLib
    .lookupFunction<
      Uint8 Function(ObjcId, ObjcId, ObjcId),
      int Function(ObjcId, ObjcId, ObjcId)
    >('objc_msgSend');

class MetalFrameLimiter {
  MetalFrameLimiter._(this._queue);

  /// The limiter, or null where it doesn't apply (not macOS, switched off,
  /// not on the main thread, or no Flutter view controller found yet).
  static MetalFrameLimiter? create() {
    if (!Platform.isMacOS) return null;
    if (Platform.environment['MCSM_GPU_FRAME_GATE'] == 'off') return null;
    if (msgSendBool(objcClass(cString('NSThread')), sel('isMainThread')) == 0) {
      return null;
    }
    final queue = _engineQueue();
    return queue == null ? null : MetalFrameLimiter._(queue);
  }

  final ObjcId _queue;
  final List<ObjcId> _markers = [];

  /// Frames that waited, the time they waited, and waits cut off at
  /// [maxWaitUs] (the run log).
  int waits = 0;
  int waitedUs = 0;
  int timeouts = 0;

  /// The longest a frame waits for the GPU.
  static const maxWaitUs = 250000;

  /// Call at the start of every frame, before it builds anything.
  void beginFrame() {
    final marker = msgSend(_queue, sel('commandBuffer'));
    if (marker == nullptr) return;
    cfRetain(marker);
    _msgWait(marker, sel('commit'));
    _markers.add(marker);
    if (_markers.length <= 2) return;
    final oldest = _markers.removeAt(0);
    // MTLCommandBufferStatusCompleted = 4, Error = 5. A bounded wait, never
    // waitUntilCompleted: should the queue not drain (a window the OS
    // stopped presenting, a stuck command buffer), the frame goes on after
    // [maxWaitUs] rather than hang the main thread.
    if (_msgStatus(oldest, sel('status')) < 4) {
      final sw = Stopwatch()..start();
      while (_msgStatus(oldest, sel('status')) < 4 &&
          sw.elapsedMicroseconds < maxWaitUs) {
        _usleep(200);
      }
      waits++;
      waitedUs += sw.elapsedMicroseconds;
      if (_msgStatus(oldest, sel('status')) < 4) timeouts++;
    }
    cfRelease(oldest);
  }

  /// The run's summary line.
  String get summary =>
      'frames waited for the GPU (macOS frame limiter): $waits, '
      '${(waitedUs / 1000).toStringAsFixed(0)} ms, $timeouts cut off at '
      '${maxWaitUs ~/ 1000} ms';

  static ObjcId? _engineQueue() {
    final app = msgSend(
      objcClass(cString('NSApplication')),
      sel('sharedApplication'),
    );
    final windows = msgSend(app, sel('windows'));
    final n = msgSendCount(windows, sel('count'));
    for (var i = 0; i < n; i++) {
      final w = msgSendIndex(windows, sel('objectAtIndex:'), i);
      final vc = msgSend(w, sel('contentViewController'));
      if (vc == nullptr ||
          _msgResponds(vc, sel('respondsToSelector:'), sel('engine')) == 0) {
        continue;
      }
      final engine = msgSend(vc, sel('engine'));
      if (engine == nullptr ||
          _msgResponds(engine, sel('respondsToSelector:'), sel('renderer')) ==
              0) {
        continue;
      }
      final renderer = msgSend(engine, sel('renderer'));
      if (renderer == nullptr ||
          _msgResponds(
                renderer,
                sel('respondsToSelector:'),
                sel('commandQueue'),
              ) ==
              0) {
        continue;
      }
      final queue = msgSend(renderer, sel('commandQueue'));
      if (queue != nullptr) return queue;
    }
    return null;
  }
}
