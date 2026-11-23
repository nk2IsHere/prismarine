import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:prismarine_audio/prismarine_audio.dart';

import '../native.dart';

/// A waveform FMOD keeps in memory, decoded whole on the native worker
/// thread: until [ready]
/// the engine starts its instruments late (FMOD 1.06's rule). [channels],
/// [sampleRate] and [frames] are the bank's until the decode lands.
class AsyncPcmSource implements LoadingPcmSource {
  AsyncPcmSource.start(
    this.path, {
    required int channels,
    required int sampleRate,
    required int frames,
  }) : _channels = channels,
       _rate = sampleRate,
       _frames = frames,
       _job = using(
         (a) => decodeAsync(path.toNativeUtf8(allocator: a).cast()),
       ) {
    _since.start();
  }

  final _since = Stopwatch();

  /// Called once when the data lands: ms since the request, ms the copy into
  /// the Dart heap took (the render isolate's audio trace).
  void Function(double waitMs, double copyMs)? onReady;

  final String path;
  final int _channels, _rate, _frames;
  ffi.Pointer<NativeJob> _job;
  MemoryPcmSource? _data;

  /// The decode failed: the source plays silence.
  bool failed = false;

  @override
  bool get ready {
    if (_data != null || failed) return true;
    final s = jobState(_job);
    if (s == 0) return false;
    final wait = _since.elapsedMicroseconds / 1000;
    final copy = Stopwatch()..start();
    if (s < 0) {
      failed = true;
    } else {
      using((a) {
        final f = a<ffi.Int64>(), c = a<ffi.Int32>(), r = a<ffi.Int32>();
        final p = jobResult(_job, f, c, r);
        _data = MemoryPcmSource(
          Float32List.fromList(p.asTypedList(f.value * c.value)),
          channels: c.value,
          sampleRate: r.value,
        );
      });
    }
    jobRelease(_job);
    _job = ffi.nullptr;
    onReady?.call(wait, copy.elapsedMicroseconds / 1000);
    return true;
  }

  @override
  int get channels => _data?.channels ?? _channels;
  @override
  int get sampleRate => _data?.sampleRate ?? _rate;
  @override
  int get frames => _data?.frames ?? _frames;

  @override
  int read(Float32List out, int frame, int count) {
    final d = _data;
    if (d != null) return d.read(out, frame, count);
    if (frame < 0 || frame >= frames) return 0;
    final n = (frames - frame).clamp(0, count);
    out.fillRange(0, n * channels, 0);
    return n;
  }
}
