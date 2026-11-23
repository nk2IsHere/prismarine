import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:prismarine_audio/prismarine_audio.dart';

import '../native.dart';

/// A waveform FMOD streams (WAIB loading mode 2), decoded incrementally by the native feeder:
/// opening decodes only a head, and reads copy decoded frames (silence where
/// the feeder hasn't reached yet). Each concurrent reader position gets its
/// own native stream, as FMOD opens one per playing instrument.
class StreamingPcmSource implements LoadingPcmSource {
  StreamingPcmSource._(
    this.path,
    ffi.Pointer<NativeStream> first, {
    required this.channels,
    required this.sampleRate,
    required this.frames,
  }) {
    _streams.add(_Tap(first));
  }

  /// Opens [path] (an `.ogg`) on the feeder thread; [channels],
  /// [sampleRate] and [frames] are the bank's (the file agrees). A
  /// [FormatException] when the file is missing.
  factory StreamingPcmSource.open(
    String path, {
    required int channels,
    required int sampleRate,
    required int frames,
  }) {
    if (!File(path).existsSync()) {
      throw FormatException('$path: missing audio file');
    }
    return StreamingPcmSource._(
      path,
      _open(path),
      channels: channels,
      sampleRate: sampleRate,
      frames: frames,
    );
  }

  /// The first stream is open (or failed: it plays silence rather than
  /// holding its event forever).
  @override
  bool get ready => streamReady(_streams.first.stream) != 0;

  /// The file failed to open or decode.
  bool get failed => streamReady(_streams.first.stream) < 0;

  static ffi.Pointer<NativeStream> _open(String path) => using(
    (a) => streamOpen(path.toNativeUtf8(allocator: a).cast(), headSeconds),
  );

  /// The head decoded at open: a start or a loop back to the beginning
  /// plays at once while the feeder moves.
  static const headSeconds = 0.5;

  /// At most this many native streams per waveform (concurrent voices).
  static const maxTaps = 4;

  final String path;
  @override
  final int channels, sampleRate, frames;
  final _streams = <_Tap>[];
  ffi.Pointer<ffi.Float> _buf = ffi.nullptr;
  int _bufFrames = 0;

  /// Frames read as silence because the feeder hadn't decoded them.
  int takeMissing() {
    var m = 0;
    for (final t in _streams) {
      m += streamTakeMissing(t.stream);
    }
    return m;
  }

  _Tap _tapFor(int frame) {
    // The head is in every stream: a read there (a start, a loop back to
    // the beginning) takes the latest reader's, which then seeks past it.
    if (frame < headSeconds * sampleRate) {
      var best = _streams.first;
      for (final t in _streams) {
        if (t.used > best.used) best = t;
      }
      if (frame >= best.end || frame < best.start - 2) return best;
    }
    for (final t in _streams) {
      if (frame >= t.start - 2 && frame <= t.end + 4096) return t;
    }
    if (_streams.length < maxTaps) {
      final t = _Tap(_open(path));
      _streams.add(t);
      return t;
    }
    _streams.sort((a, b) => a.used.compareTo(b.used));
    return _streams.first;
  }

  int _clock = 0;

  @override
  int read(Float32List out, int frame, int count) {
    if (frame < 0 || frame >= frames || count <= 0) return 0;
    final n = (frames - frame).clamp(0, count);
    if (n > _bufFrames) {
      if (_buf != ffi.nullptr) malloc.free(_buf);
      _bufFrames = n < 4096 ? 4096 : n;
      _buf = malloc<ffi.Float>(_bufFrames * channels);
    }
    final t = _tapFor(frame)
      ..start = frame
      ..end = frame + n
      ..used = ++_clock;
    if (streamReady(t.stream) != 1) {
      out.fillRange(0, n * channels, 0);
      return n;
    }
    streamRead(t.stream, _buf, frame, n);
    out.setRange(0, n * channels, _buf.asTypedList(n * channels));
    return n;
  }

  void close() {
    for (final t in _streams) {
      streamClose(t.stream);
    }
    _streams.clear();
    if (_buf != ffi.nullptr) malloc.free(_buf);
    _buf = ffi.nullptr;
  }
}

class _Tap {
  _Tap(this.stream);
  final ffi.Pointer<NativeStream> stream;
  int start = 0, end = 0, used = 0;
}
