// Limits the frames in flight on macOS. The frames of the app wait for the
// GPU.
//
// The raster thread writes the vertices and uniforms of each composite into a
// ring of four arenas, the HostBuffer of Impeller. It reuses an arena four
// frames later without waiting for the GPU. On iOS the few drawables of the
// CAMetalLayer hold it back. On macOS nothing does. Composites queue more than
// four deep while the GPU work of the 3D scene falls behind. One then reads the
// arena of a later one. The result is streaked triangles, garbled text or a
// panel of the wrong colour for one or more frames.
//
// The limiter bounds that queue as the drawables do on iOS. Each frame it
// commits an empty marker command buffer on the Metal queue of the engine.
// It polls for at most 250 ms until the marker of two frames before has
// completed. With the two-frame pipeline of Flutter that marker is composite
// k − 4, whose arena frame k reuses. The wait is only the GPU backlog beyond
// it.
//
// It calls the Objective-C runtime of objc.dart through dart:ffi.
// `PRISMARINE_GPU_FRAME_GATE=off` turns the limiter off to show the race.
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

  /// Returns the limiter, or null where it does not apply. It does not apply
  /// on a system other than macOS, when it is switched off, off the main
  /// thread or before a Flutter view controller exists.
  static MetalFrameLimiter? create() {
    if (!Platform.isMacOS) return null;
    final gate =
        Platform.environment['PRISMARINE_GPU_FRAME_GATE'] ??
        Platform.environment['MCSM_GPU_FRAME_GATE'];
    if (gate == 'off') return null;
    if (msgSendBool(objcClass(cString('NSThread')), sel('isMainThread')) == 0) {
      return null;
    }
    final queue = _engineQueue();
    return queue == null ? null : MetalFrameLimiter._(queue);
  }

  final ObjcId _queue;
  final List<ObjcId> _markers = [];

  /// The number of frames that waited, the time they waited and the number
  /// of waits cut off at [maxWaitUs].
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
    // MTLCommandBufferStatusCompleted is 4 and Error is 5. The wait is
    // bounded and does not use waitUntilCompleted. A queue that does not
    // drain, such as for a window that the OS stopped presenting or a stuck
    // command buffer, must not hang the main thread. The frame goes on after
    // [maxWaitUs].
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

  /// The summary line of the run.
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
