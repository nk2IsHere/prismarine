import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// Real-time output of PCM rendered in Dart, as f32 48 kHz interleaved stereo
/// pushed into a ring that the default output device of the system drains
/// (native/src/push.rs). Its audio clock counts the frames that the device has
/// taken. A paused stream takes nothing. A muted stream takes and plays
/// silence. A ring that runs dry plays silence without advancing the clock
/// until 50 ms are queued again. Each time counts as an underrun.
///
/// Any isolate may use a stream by its [address] ([PcmPushStream.at]). One
/// isolate pushes.
class PcmPushStream {
  PcmPushStream._(this.address);

  /// The stream that another isolate opened. Only that isolate calls
  /// [dispose].
  PcmPushStream.at(this.address);

  /// Opens the default output device. Throws a [StateError] when none opens,
  /// such as in a VM or a container without a sound device.
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

  /// Queues the interleaved stereo [pcm]. Returns the frames taken, fewer
  /// only when the ring of two seconds is full.
  int push(Float32List pcm) =>
      _gone ? 0 : pushPcm(_s, pcm.address, pcm.length ~/ 2);

  /// The number of frames that the device has taken so far.
  int get consumedFrames => _gone ? 0 : pushConsumed(_s);

  /// [consumedFrames] in seconds.
  double get consumed => consumedFrames / 48000;

  set paused(bool v) => _gone ? null : pushSetPaused(_s, v ? 1 : 0);
  set muted(bool v) => _gone ? null : pushSetMuted(_s, v ? 1 : 0);

  /// Returns the number of times the ring ran dry since the last call.
  int takeUnderruns() => _gone ? 0 : pushUnderruns(_s);

  /// Stops the device and frees the stream. The isolate that opened it calls
  /// this once nothing pushes any more.
  void dispose() {
    if (_gone) return;
    _gone = true;
    pushDestroy(_s);
  }
}
