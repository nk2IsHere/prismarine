import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// The Dart mixer's real-time output (`--mixer=dart`): rendered PCM (f32
/// 48 kHz interleaved stereo) pushed into a ring the system's default
/// output device drains (native/out/src/push.rs, through cpal, as the
/// native mixer outputs). Its audio clock is the frames the device has
/// taken: a paused stream takes nothing, a muted one takes and plays
/// silence, a ring that runs dry plays silence without advancing the clock
/// until 50 ms are queued again (each time is an underrun).
///
/// Any isolate may use a stream by its [address] ([PcmPushStream.at]); one
/// isolate pushes.
class PcmPushStream {
  PcmPushStream._(this.address);

  /// The stream another isolate opened (not owned: [dispose] there only).
  PcmPushStream.at(this.address);

  /// Opens the default output device. Throws a [StateError] when none
  /// opens (no sound device: a VM, a container).
  factory PcmPushStream.start() {
    final err = malloc<ffi.Int32>();
    try {
      final s = pushStart(err);
      if (s == ffi.nullptr) {
        throw StateError('no audio output device (error ${err.value})');
      }
      return PcmPushStream._(s.address);
    } finally {
      malloc.free(err);
    }
  }

  final int address;
  var _gone = false;

  ffi.Pointer<NativePushStream> get _s => ffi.Pointer.fromAddress(address);

  /// Queues [pcm] (interleaved stereo); the frames taken (fewer only when
  /// the ring, two seconds long, is full).
  int push(Float32List pcm) =>
      _gone ? 0 : pushPcm(_s, pcm.address, pcm.length ~/ 2);

  /// Frames the device has taken so far.
  int get consumedFrames => _gone ? 0 : pushConsumed(_s);

  /// [consumedFrames] in seconds.
  double get consumed => consumedFrames / 48000;

  set paused(bool v) => _gone ? null : pushSetPaused(_s, v ? 1 : 0);
  set muted(bool v) => _gone ? null : pushSetMuted(_s, v ? 1 : 0);

  /// Times the ring ran dry since the last call.
  int takeUnderruns() => _gone ? 0 : pushUnderruns(_s);

  /// Stops the device and frees the stream (the isolate that opened it,
  /// once nothing pushes any more).
  void dispose() {
    if (_gone) return;
    _gone = true;
    pushDestroy(_s);
  }
}
