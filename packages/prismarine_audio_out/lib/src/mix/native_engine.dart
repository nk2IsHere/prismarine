import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:prismarine_audio/prismarine_audio.dart';

import 'native.dart';

/// Posts [AudioCommand]s into a native engine from any isolate. It holds the
/// address of the engine and the directory of the sounds of starts, and it
/// can be sent to another isolate.
class NativeMixerPort {
  const NativeMixerPort(this.address, this.soundDir);

  final int address;

  /// A start's sound is the file `<soundDir>/<sound>`.
  final String soundDir;

  // alloc: a Pointer passed straight to a native call is not boxed
  ffi.Pointer<NativeMixer> get _e => ffi.Pointer.fromAddress(address);

  /// Applies [c] at frame [at], or before the next frame when [at] is below
  /// 0. Returns false when the command ring was full and dropped it.
  bool post(AudioCommand c, int at) {
    final r = switch (c) {
      StartEvent(:final path, :final seek, :final sound, :final late) => _send(
        c,
        at,
        1,
        seek: seek,
        late: late ?? 0,
        hasLate: late != null,
        name: _text(0, path, null, false),
        sound: sound == null ? ffi.nullptr : _text(1, soundDir, sound, false),
      ),
      SetParameter(:final name, :final value) => _send(
        c,
        at,
        2,
        value: value,
        name: _text(0, name, null, true),
      ),
      SetVolume(:final volume, :final keepTail) => _send(
        c,
        at,
        3,
        value: volume,
        keepTail: keepTail ?? -1,
      ),
      StopEvent(:final fade, :final keepTail, :final viaParameter) => _send(
        c,
        at,
        4,
        flag: !fade,
        keepTail: keepTail ?? -1,
        via: viaParameter == null
            ? ffi.nullptr
            : _text(2, viaParameter, null, true),
      ),
      SetPaused(:final paused) => _send(c, at, 5, flag: paused),
      StartMixState(:final path) => _send(
        c,
        at,
        7,
        name: _text(0, path, null, false),
      ),
      SetMixStateParameter(:final name, :final value) => _send(
        c,
        at,
        8,
        value: value,
        name: _text(0, name, null, true),
      ),
      StopMixState() => _send(c, at, 9),
      SetSpatial(:final azimuth, :final distance, :final cone) => _send(
        c,
        at,
        12,
        value: azimuth,
        seek: distance,
        late: cone,
        hasLate: true,
      ),
    };
    return r == 0;
  }

  int _send(
    AudioCommand c,
    int at,
    int op, {
    double value = 0,
    double seek = 0,
    double late = 0,
    bool hasLate = false,
    bool flag = false,
    double keepTail = -1,
    ffi.Pointer<ffi.Char>? name,
    ffi.Pointer<ffi.Char>? sound,
    ffi.Pointer<ffi.Char>? via,
  }) => mixPost(
    _e,
    op,
    c.id,
    at,
    value,
    seek,
    hasLate ? 1 : 0,
    late,
    flag ? 1 : 0,
    keepTail,
    name ?? ffi.nullptr,
    sound ?? ffi.nullptr,
    via ?? ffi.nullptr,
  );

  /// The UTF-8 buffers of the texts of a post, kept by the isolate.
  static final _texts = [
    for (var i = 0; i < 3; i++) malloc<ffi.Uint8>(_textCap),
  ];
  static final _chars = [for (final t in _texts) t.cast<ffi.Char>()];
  static const _textCap = 4096;

  /// Writes [a], then `/` and [b] when [b] is given, into text buffer [k] as
  /// NUL-terminated UTF-8, with ASCII letters lower-cased when [lower].
  /// Returns the buffer.
  static ffi.Pointer<ffi.Char> _text(int k, String a, String? b, bool lower) {
    final p = _texts[k];
    var n = _utf8(p, 0, a, lower);
    if (b != null) {
      if (n < _textCap - 1) p[n++] = 0x2f;
      n = _utf8(p, n, b, lower);
    }
    p[n] = 0;
    return _chars[k];
  }

  static int _utf8(ffi.Pointer<ffi.Uint8> p, int n, String s, bool lower) {
    const end = _textCap - 5;
    for (var i = 0; i < s.length && n < end; i++) {
      var u = s.codeUnitAt(i);
      if (u >= 0xd800 && u < 0xdc00 && i + 1 < s.length) {
        final l = s.codeUnitAt(i + 1);
        if (l >= 0xdc00 && l < 0xe000) {
          u = 0x10000 + ((u - 0xd800) << 10) + (l - 0xdc00);
          i++;
        }
      }
      if (u < 0x80) {
        p[n++] = lower && u >= 0x41 && u <= 0x5a ? u + 0x20 : u;
      } else if (u < 0x800) {
        p[n++] = 0xc0 | (u >> 6);
        p[n++] = 0x80 | (u & 0x3f);
      } else if (u < 0x10000) {
        p[n++] = 0xe0 | (u >> 12);
        p[n++] = 0x80 | ((u >> 6) & 0x3f);
        p[n++] = 0x80 | (u & 0x3f);
      } else {
        p[n++] = 0xf0 | (u >> 18);
        p[n++] = 0x80 | ((u >> 12) & 0x3f);
        p[n++] = 0x80 | ((u >> 6) & 0x3f);
        p[n++] = 0x80 | (u & 0x3f);
      }
    }
    return n;
  }

  /// Starts a new generation of sample bindings and lets the older ones go.
  void sceneChanged() => mixScene(_e);

  /// The audio frames that the output device took so far.
  int get consumedFrames => mixConsumed(_e);
}

/// The native render of the audio engine as an [AudioRenderer], with the
/// same bits as [AudioEngine]. In lockstep [render] runs on the caller's
/// thread, and every sample is decoded before its start is posted. In real
/// time [startDevice] renders in the callback of the output device.
class NativeAudioEngine implements AudioRenderer {
  NativeAudioEngine._(this._e, this.soundDir, this._problems);

  /// Makes an engine from the bytes of [projectBlob], which another isolate
  /// can write. A start's sound is the file `<soundDir>/<sound>`. With
  /// [realtime] streamed waveforms stream and decodes are not waited for.
  factory NativeAudioEngine.fromBlob(
    Uint8List blob, {
    required String soundDir,
    int seed = 0,
    bool realtime = false,
    AudioRules rules = const AudioRules(),
    Set<String> problems = const {},
  }) {
    final e = using((a) {
      final p = a<ffi.Uint8>(blob.length);
      p.asTypedList(blob.length).setAll(0, blob);
      return mixCreate(
        p,
        blob.length,
        seed,
        realtime ? 1 : 0,
        rules.reportLag,
        rules.lateStartMinimum,
        rules.wholeMsLengths ? 1 : 0,
      );
    });
    if (e == ffi.nullptr) throw StateError('native mixer: bad model');
    return NativeAudioEngine._(e, soundDir, {...problems});
  }

  ffi.Pointer<NativeMixer> _e;
  final String soundDir;
  final Set<String> _problems;
  ffi.Pointer<ffi.Float> _buf = ffi.nullptr;
  int _bufFrames = 0;

  /// The address of the engine, for [NativeMixerPort]s on other isolates.
  int get address => _e.address;

  NativeMixerPort get port => NativeMixerPort(_e.address, soundDir);

  /// The engine was freed by [dispose]. Every call after it does nothing and
  /// answers what the engine last said.
  bool get _gone => _e == ffi.nullptr;

  @override
  int get position => _gone ? _lastPosition : (_lastPosition = mixPosition(_e));
  int _lastPosition = 0;

  /// Moves the render head in lockstep only, since a running device owns
  /// the render head.
  @override
  set position(int frames) {
    if (_gone) return;
    if (mixSetPosition(_e, frames) != 0) {
      throw StateError('native mixer: the render head moves only in lockstep');
    }
  }

  @override
  void schedule(AudioCommand c, {required int at}) => _post(c, at);

  @override
  void apply(AudioCommand c) => _post(c, -1);

  void _post(AudioCommand c, int at) {
    if (_gone) return;
    if (!port.post(c, at)) {
      _problems.add('audio command ring full: a command was dropped');
    }
  }

  @override
  Float32List render(int frames) {
    if (_gone) return Float32List(frames * 2);
    if (frames > _bufFrames) {
      if (_buf != ffi.nullptr) malloc.free(_buf);
      _bufFrames = frames < 4096 ? 4096 : frames;
      _buf = malloc<ffi.Float>(_bufFrames * 2);
    }
    mixRender(_e, _buf, frames);
    return Float32List.fromList(_buf.asTypedList(frames * 2));
  }

  /// Returns the problems that the engine reported since the last call, each
  /// once.
  List<String> takeProblems() {
    final out = <String>[];
    if (_gone) return out;
    using((a) {
      final b = a<ffi.Uint8>(512);
      for (;;) {
        final n = mixProblem(_e, b, 512);
        if (n == 0) break;
        out.add(utf8.decode(b.asTypedList(n), allowMalformed: true));
      }
    });
    _problems.addAll(out);
    return out;
  }

  @override
  Set<String> get problems {
    takeProblems();
    return _problems;
  }

  /// Starts the service thread and the output device for real time. Returns
  /// 0, or the error of the platform.
  int startDevice() => _gone ? -1 : mixStart(_e);

  set paused(bool v) => _gone ? null : mixSetPaused(_e, v ? 1 : 0);
  set muted(bool v) => _gone ? null : mixSetMuted(_e, v ? 1 : 0);

  /// The frames that the device took.
  int get consumedFrames =>
      _gone ? _lastConsumed : (_lastConsumed = mixConsumed(_e));
  int _lastConsumed = 0;

  /// Returns the timing records of the callbacks since the last call, each
  /// the wall µs since the start, the frames, the render µs and the µs since
  /// the previous callback.
  List<(int, int, int, int)> takeStats() => _gone
      ? const []
      : using((a) {
          const max = 1024;
          final p = a<ffi.Int64>(max * 4);
          final out = <(int, int, int, int)>[];
          for (;;) {
            final n = mixStats(_e, p, max);
            final v = p.asTypedList(n * 4);
            for (var i = 0; i < n; i++) {
              out.add((v[i * 4], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3]));
            }
            if (n < max) break;
          }
          return out;
        });

  /// Returns the frames that streams read as silence since the last call.
  int takeMissing() => _gone ? 0 : mixMissing(_e);

  /// Stops the device and frees the engine. No isolate may post after it.
  void dispose() {
    if (_e == ffi.nullptr) return;
    mixDestroy(_e);
    _e = ffi.nullptr;
    if (_buf != ffi.nullptr) malloc.free(_buf);
    _buf = ffi.nullptr;
  }
}
