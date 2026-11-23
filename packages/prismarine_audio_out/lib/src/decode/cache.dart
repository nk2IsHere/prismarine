import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:prismarine_audio/prismarine_audio.dart';

import '../native.dart';

/// The process-wide decoded-audio cache (native/src/decode/cache.rs). It
/// holds whole-file decodes in native memory, decoded on low-priority native
/// threads and keyed by path. Every isolate sees the same cache. One isolate
/// asks for what is coming ([want]) and another plays it
/// ([CachedPcmSource]).
abstract final class PcmCache {
  /// Asks for [path] ahead of need. Returns its state: 0 queued, 1 ready,
  /// 2 decoding, −1 failed.
  static int want(String path) =>
      using((a) => pcmWant(path.toNativeUtf8(allocator: a).cast()));

  /// A scene change: what nobody holds and nobody wanted since the change
  /// before this one is dropped.
  static void sceneChanged() => pcmSceneChanged();

  /// Decoded bytes kept before the oldest unheld entries are dropped.
  static set budget(int bytes) => pcmSetBudget(bytes);

  /// The default budget: 512 MB of float32 (about 45 min of mono 48 kHz).
  static const defaultBudget = 512 << 20;

  /// Drops everything nobody holds.
  static void clear() => pcmClear();

  static PcmCacheStats stats() => using((a) {
    final p = a<ffi.Int64>(12);
    pcmStats(p);
    return PcmCacheStats(p.asTypedList(12).toList());
  });
}

/// [PcmCache.stats]: entries, decoded bytes, queued, decodes done, decode
/// time, dropped, acquires that were ready / not ready, waits and their
/// time, wants, failed decodes.
class PcmCacheStats {
  PcmCacheStats(List<int> v)
    : entries = v[0],
      bytes = v[1],
      queued = v[2],
      decoded = v[3],
      decodeMs = v[4] / 1000,
      dropped = v[5],
      hits = v[6],
      misses = v[7],
      waits = v[8],
      waitMs = v[9] / 1000,
      wanted = v[10],
      failed = v[11];
  final int entries, bytes, queued, decoded, dropped, hits, misses, waits;
  final int wanted, failed;
  final double decodeMs, waitMs;

  Map<String, Object> toJson() => {
    'entries': entries,
    'mb': (bytes / 1e5).round() / 10,
    'queued': queued,
    'decoded': decoded,
    'decodeMs': decodeMs.round(),
    'dropped': dropped,
    'hits': hits,
    'misses': misses,
    'waits': waits,
    'waitMs': (waitMs * 10).round() / 10,
    'wanted': wanted,
    'failed': failed,
  };
}

/// A whole file from [PcmCache], held while this object lives (a native
/// finalizer gives the reference back): the samples stay in native memory
/// and reads copy only the frames asked for. Until the decode lands it is a
/// [LoadingPcmSource] with the format given ([channels], [sampleRate],
/// [frames] as given); [wait] blocks until it is there. [ffi.Finalizable]
/// keeps it alive to the end of every method that reads its view.
class CachedPcmSource implements LoadingPcmSource, ffi.Finalizable {
  CachedPcmSource.acquire(
    this.path, {
    int channels = 1,
    int sampleRate = 48000,
    int frames = 0,
  }) : _channels = channels,
       _rate = sampleRate,
       _frames = frames,
       _entry = using(
         (a) => pcmAcquire(path.toNativeUtf8(allocator: a).cast()),
       ) {
    _finalizer.attach(this, _entry.cast(), externalSize: 0);
    _readyAtAcquire = pcmState(_entry) == 1;
    _since.start();
  }

  final _since = Stopwatch();

  /// Called once when a source that wasn't ready at acquire becomes ready:
  /// ms since the acquire (the render isolate's audio trace).
  void Function(double waitMs)? onReady;

  static final _finalizer = ffi.NativeFinalizer(pcmReleasePtr.cast());

  final String path;
  final ffi.Pointer<NativePcm> _entry;
  int _channels, _rate, _frames;
  Float32List? _view;
  bool _failed = false;
  late final bool _readyAtAcquire;

  /// The data was decoded before it was asked for (a preload hit).
  bool get wasPreloaded => _readyAtAcquire;

  /// The decode failed: the source plays silence.
  bool get failed => _failed;

  @override
  bool get ready {
    if (_view != null || _failed) return true;
    final s = pcmState(_entry);
    if (s == 1 || s == -1) {
      _take(s);
      return true;
    }
    return false;
  }

  /// Blocks until decoded (on this thread when no worker has started it).
  /// False when the file failed.
  bool wait() {
    if (_view != null) return true;
    if (_failed) return false;
    _take(pcmWait(_entry));
    return !_failed;
  }

  void _take(int state) {
    onReady?.call(_since.elapsedMicroseconds / 1000);
    if (state != 1) {
      _failed = true;
      return;
    }
    using((a) {
      final f = a<ffi.Int64>(), c = a<ffi.Int32>(), r = a<ffi.Int32>();
      final p = pcmData(_entry, f, c, r);
      _frames = f.value;
      _channels = c.value;
      _rate = r.value;
      // A view on native memory: valid while this source holds its reference
      // (it never escapes this object).
      _view = p.asTypedList(_frames * _channels);
    });
  }

  @override
  int get channels => _channels;
  @override
  int get sampleRate => _rate;
  @override
  int get frames => _frames;

  @override
  int read(Float32List out, int frame, int count) {
    if (frame < 0 || frame >= frames) return 0;
    final n = (frames - frame).clamp(0, count);
    final v = _view;
    if (v == null) {
      out.fillRange(0, n * channels, 0);
    } else {
      out.setRange(0, n * channels, v, frame * channels);
    }
    return n;
  }
}
