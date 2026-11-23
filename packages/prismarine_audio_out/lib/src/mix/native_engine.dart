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

  ffi.Pointer<NativeMixer> get _e => ffi.Pointer.fromAddress(address);

  /// Applies [c] at frame [at], or before the next frame when [at] is below
  /// 0. Returns false when the command ring was full and dropped it.
  bool post(AudioCommand c, int at) => using((a) {
    ffi.Pointer<ffi.Char> s(String? v) =>
        v == null ? ffi.nullptr : v.toNativeUtf8(allocator: a).cast();
    int send(
      int op, {
      double value = 0,
      double seek = 0,
      double? late,
      bool flag = false,
      double? keepTail,
      String? name,
      String? sound,
      String? via,
    }) => mixPost(
      _e,
      op,
      c.id,
      at,
      value,
      seek,
      late == null ? 0 : 1,
      late ?? 0,
      flag ? 1 : 0,
      keepTail ?? -1,
      s(name),
      s(sound),
      s(via),
    );
    final r = switch (c) {
      StartEvent(:final path, :final seek, :final sound, :final late) => send(
        1,
        seek: seek,
        late: late,
        name: path,
        sound: sound == null ? null : '$soundDir/$sound',
      ),
      SetParameter(:final name, :final value) => send(
        2,
        value: value,
        name: name.toLowerCase(),
      ),
      SetVolume(:final volume, :final keepTail) => send(
        3,
        value: volume,
        keepTail: keepTail,
      ),
      StopEvent(:final fade, :final keepTail, :final viaParameter) => send(
        4,
        flag: !fade,
        keepTail: keepTail,
        via: viaParameter?.toLowerCase(),
      ),
      SetPaused(:final paused) => send(5, flag: paused),
      StartMixState(:final path) => send(7, name: path),
      SetMixStateParameter(:final name, :final value) => send(
        8,
        value: value,
        name: name.toLowerCase(),
      ),
      StopMixState() => send(9),
      SetSpatial(:final azimuth, :final distance, :final cone) => send(
        12,
        value: azimuth,
        seek: distance,
        late: cone,
      ),
    };
    return r == 0;
  });

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
