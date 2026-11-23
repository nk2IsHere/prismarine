import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import 'biquad.dart';
import 'dsp.dart';

/// FMOD_DSP_TYPE_HIGHPASS (5): cutoff Hz (0), resonance (1). One RBJ
/// high-pass biquad with Q = resonance (O: an impulse matches to 16-bit at
/// 500 Hz/1 and 2 kHz/3).
class Highpass extends Dsp {
  Highpass() : super([5000, 1]) {
    _update();
  }
  final _s = Biquad();

  @override
  void changed(int index) => _update();

  void _update() => _s.highpass(params[0], math.max(params[1], 0.01));

  @override
  bool process51(Float32List buf, int frames) =>
      processPairs51(buf, frames, Highpass.new);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    for (var i = 0; i < frames * 2; i++) {
      buf[i] = _s.tick(i & 1, buf[i]);
    }
    return mono;
  }
}

/// FMOD_DSP_TYPE_PARAMEQ (12): centre Hz (0), bandwidth (1), gain dB (2).
/// One RBJ peaking biquad with A = 10^(gain/20) and Q = 1/bandwidth (O: the
/// impulse responses at 1 kHz/1/+6 and 300 Hz/2.5/−12 match to 16-bit; the
/// centre moves by twice the gain).
class ParamEq extends Dsp {
  ParamEq() : super([8000, 1, 0]) {
    _update();
  }
  final _s = Biquad();

  @override
  void changed(int index) => _update();

  void _update() => _s.peaking(params[0], params[1], params[2]);

  @override
  bool process51(Float32List buf, int frames) =>
      processPairs51(buf, frames, ParamEq.new);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    if (params[2] == 0) return mono;
    for (var i = 0; i < frames * 2; i++) {
      buf[i] = _s.tick(i & 1, buf[i]);
    }
    return mono;
  }
}

/// FMOD_DSP_TYPE_DISTORTION (9), also Studio's "FMOD Distortion": level (0).
/// y = (1 + k)·x / (1 + k·|x|), k = 2·level / (1 − level) (O: a −1..1 ramp
/// matches to 16-bit at levels 0, 0.225 and 0.5).
class Distortion extends Dsp {
  Distortion() : super([0.5]);

  @override
  bool process51(Float32List buf, int frames) =>
      processPairs51(buf, frames, Distortion.new);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final l = params[0].clamp(0.0, 0.9999);
    if (l == 0) return mono;
    final k = 2 * l / (1 - l);
    for (var i = 0; i < frames * 2; i++) {
      final x = buf[i];
      buf[i] = (1 + k) * x / (1 + k * x.abs());
    }
    return mono;
  }
}

/// A stereo delay line, sized on demand.
class _Line {
  Float32List _b = Float32List(2);
  int _w = 0;

  void size(int frames) {
    if (_b.length >= (frames + 2) * 2) return;
    _b = Float32List((frames + 2) * 2);
    _w = 0;
  }

  int get frames => _b.length ~/ 2;

  void write(int ch, double v) => _b[_w * 2 + ch] = v;

  /// The sample written [d] frames ago (0 = this frame's write).
  double read(int ch, int d) {
    var i = _w - d;
    if (i < 0) i += frames;
    return _b[i * 2 + ch];
  }

  void advance() {
    if (++_w == frames) _w = 0;
  }

  void clear() => _b.fillRange(0, _b.length, 0);
}

/// FMOD_DSP_TYPE_ECHO (6): delay ms (0), feedback % (1), dry dB (2), wet dB
/// (3). out = dry·x + wet·line, line[n] = x[n − D] + feedback·line[n − D],
/// D = delay·48 samples (O: impulse taps at exactly 460 ms × 48, each
/// feedback × the last; dry and wet in dB, −80 = off).
class Echo extends Dsp {
  Echo() : super([500, 50, 0, 0]) {
    _update();
  }
  final _line = _Line();
  int _d = 1;

  /// Frames since the line last took in sound.
  int _quiet = 1 << 30;

  @override
  void changed(int index) {
    if (index == 0) _update();
  }

  void _update() {
    _d = math.max(1, (params[0] * mixRate / 1000).round());
    _line.size(_d);
  }

  @override
  bool get ringing => _quiet < _d;

  @override
  void idle(int frames) => _quiet += frames;

  @override
  bool process51(Float32List buf, int frames) =>
      processPairs51(buf, frames, Echo.new);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final fb = params[1].clamp(0, 100) / 100;
    final dry = dbGain(params[2]), wet = dbGain(params[3]);
    for (var i = 0; i < frames; i++) {
      var loud = false;
      for (var ch = 0; ch < 2; ch++) {
        final x = buf[i * 2 + ch];
        // The line holds x + feedback·(its own output), D frames back.
        final out = _line.read(ch, _d);
        final w = x + fb * out;
        _line.write(ch, w);
        if (w.abs() > 1e-9) loud = true;
        buf[i * 2 + ch] = dry * x + wet * out;
      }
      _line.advance();
      _quiet = loud ? 0 : _quiet + 1;
    }
    return mono;
  }
}

/// FMOD_DSP_TYPE_FLANGE (8): mix % (0), depth (1), rate Hz (2). out =
/// (1 − mix)·x + mix·x[n − d], d = 480·(1 − cos 2πφ) samples (0–20 ms),
/// read with linear interpolation; φ is a float32 phase that starts at 0,
/// steps by rate/48000 per sample and wraps at 1. Depth changes nothing in
/// 1.06.02 (O: impulse trains at 0.1 and 0.25 Hz match the delay to 0.1
/// sample over 10 s with the float32 phase; depth 1, 0.4 and 0.05 render
/// identically).
class Flange extends Dsp {
  Flange() : super([50, 1, 0.1]) {
    _line.size(_max + 2);
  }
  static const _max = 960;
  final _line = _Line();
  double _phase = 0;
  int _quiet = 1 << 30;

  @override
  bool get ringing => _quiet < _max + 2;

  @override
  void idle(int frames) {
    _quiet += frames;
    _advance(frames);
  }

  void _advance(int frames) {
    final inc = _f32(params[2] / mixRate);
    var p = _phase;
    for (var i = 0; i < frames; i++) {
      p = _f32(p + inc);
      if (p >= 1) p = _f32(p - 1);
    }
    _phase = p;
  }

  static final _bits = Float32List(1);
  static double _f32(double v) {
    _bits[0] = v;
    return _bits[0];
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    final mix = params[0].clamp(0, 100) / 100;
    final inc = _f32(params[2] / mixRate);
    var p = _phase;
    for (var i = 0; i < frames; i++) {
      final d = _max / 2 * (1 - libm.cos(2 * math.pi * p));
      final k = d.floor();
      final fr = d - k;
      var loud = false;
      for (var ch = 0; ch < 2; ch++) {
        final x = buf[i * 2 + ch];
        _line.write(ch, x);
        if (x.abs() > 1e-9) loud = true;
        final a = _line.read(ch, k), b = _line.read(ch, k + 1);
        buf[i * 2 + ch] = (1 - mix) * x + mix * (a + (b - a) * fr);
      }
      _line.advance();
      _quiet = loud ? 0 : _quiet + 1;
      p = _f32(p + inc);
      if (p >= 1) p = _f32(p - 1);
    }
    _phase = p;
    return mono;
  }
}

/// FMOD_DSP_TYPE_CHORUS (14): mix % (0), rate Hz (1), depth (2), defaults
/// 100 / 0.8 / 3 [ORACLE fmod]. A transcription of fmod.dll 1.06.02's
/// chorus (see formats/telltale/fmod-runtime.md, "14 chorus"), operation for
/// operation: float32 where the exe uses SSE, the read position in double
/// (x87 at 53 bits), the delay line in 16 bits.
///
/// Tap c (of 1 or 2 channels) reads at the write position minus a delay
/// swinging between 0 and D = 48000·depth²·1e-5 samples, with linear
/// interpolation, weighted against dry = 200/(mix + 200). A depth change
/// moves the live D by 1/32 of a sample a frame; FMOD resets the effect when
/// it starts playing, so the first block resets here. Parameter changes are
/// taken at the start of a read (a 1,024-frame block).
class Chorus extends Dsp {
  Chorus() : super([100, 0.8, 3]) {
    _reset();
  }

  /// fmod.dll: (trunc(rate·120)/1000 / 1024 + 1)·1024 frames (6,144 at
  /// 48 kHz with the 1,024-frame DSP block).
  static const lineFrames = 6144;
  static final Float32List table = _table();
  static Float32List _table() {
    final t = Float32List(8192);
    for (var i = 0; i < 8192; i++) {
      // cosf(f32(i·f32(π/2))·2^-13), the CRT's SSE2 cosf: cos in double,
      // rounded once.
      t[i] = libm.cos(_f32(_f32(i * _halfPi) * (1 / 8192)));
    }
    return t;
  }

  static final double _halfPi = _f32(math.pi / 2);
  static final double _c01 = _f32(0.01);
  static final double _c1e4 = _f32(1e-4);
  static final double _c1e3 = _f32(1e-3);
  static const _offsets = [0.0, 0.25, 0.5];

  final _line = Int16List(lineFrames * 2);
  bool _fresh = true;
  int _pos = 0;
  double _phase = 0, _inc = 0;
  double _dry = 0, _target = 0, _cur = 0;
  final _w = Float64List(3);
  double _lastMix = 0, _lastRate = 0, _lastDepth = 0;

  /// Frames since the line last took in sound.
  int _quiet = 1 << 30;

  static final _bits = Float32List(1);
  static double _f32(double v) {
    _bits[0] = v;
    return _bits[0];
  }

  static double _clamp100(double v) => v < 0 ? 0 : (v > 100 ? 100 : v);

  /// The mix's gains (+0x140..+0x14c).
  void _gains(double mix) {
    _dry = _f32(200 / _f32(mix + 200));
    _w[0] = _f32(_f32(_clamp100(_f32(mix * 2)) * _c01) * _dry);
    final m4 = _f32(mix * 4);
    _w[1] = _f32(_f32(_clamp100(_f32(m4 - 200)) * _c01) * _dry);
    _w[2] = _f32(_f32(_clamp100(_f32(m4 - 300)) * _c01) * _dry);
  }

  double _depthFrames(double depth) => _f32(
    _f32(_f32(_f32(_f32(mixRate * depth) * depth) * _c1e4) * _c1e3) * 100,
  );

  void _reset() {
    _phase = 0;
    _pos = 0;
    _line.fillRange(0, _line.length, 0);
    _lastMix = _f32(params[0]);
    _gains(_lastMix);
    _lastRate = _f32(params[1]);
    _lastDepth = _f32(params[2]);
    _target = _cur = _depthFrames(_lastDepth);
    _inc = _f32(_lastRate / mixRate);
  }

  /// The read's parameter check.
  void _take() {
    final mix = _f32(params[0]), rate = _f32(params[1]);
    final depth = _f32(params[2]);
    if (depth == _lastDepth && mix == _lastMix && rate == _lastRate) return;
    final old = _lastDepth;
    _gains(mix);
    _lastDepth = depth;
    _lastMix = mix;
    _lastRate = rate;
    if (depth != old) _target = _depthFrames(depth);
    _inc = _f32(rate / mixRate);
  }

  @override
  bool get ringing => _quiet < lineFrames;

  /// One frame's glide of the live depth toward its target.
  void _glide() {
    final t = _target, c = _cur;
    if (_f32(t - 0.03125) > c) {
      _cur = _f32(c + 0.03125);
    } else if (c > _f32(t + 0.03125)) {
      _cur = _f32(c - 0.03125);
    } else {
      _cur = t;
    }
  }

  void _step() {
    final p = _f32(_phase + _inc);
    _phase = p > 1 ? _f32(p - 1) : p;
    if (++_pos == lineFrames) _pos = 0;
  }

  void _start() {
    if (!_fresh) return;
    _fresh = false;
    _reset();
  }

  @override
  void idle(int frames) {
    _start();
    for (var i = 0; i < frames; i++) {
      if ((_pos & 1023) == 0) _take();
      _glide();
      _line[_pos * 2] = 0;
      _line[_pos * 2 + 1] = 0;
      _step();
    }
    _quiet += frames;
  }

  /// The cosine LFO at phase [x] (one period over 0..1).
  static double _lfo(double x) {
    var i = _f32(x * 32768).truncate();
    if (i < 0) i = -i;
    i &= 0x7fff;
    return switch (i >> 13) {
      0 => table[i],
      1 => -table[0x3fff - i],
      2 => -table[i - 0x4000],
      _ => table[0x7fff - i],
    };
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    _start();
    final nch = mono ? 1 : 2;
    const n = lineFrames;
    for (var i = 0; i < frames; i++) {
      // FMOD reads in 1,024-frame blocks from the effect's start (the line
      // is six of them): a block takes the parameters, and the read
      // position adds the block's start and the frame within it.
      final j = _pos & 1023;
      if (j == 0) _take();
      _glide();
      var loud = false;
      for (var c = 0; c < nch; c++) {
        final x = buf[i * 2 + c];
        // cvttss2si into a 16-bit store: truncated and wrapped.
        _line[_pos * 2 + c] = _f32(x * 16384).truncate().toSigned(16);
        if (x != 0) loud = true;
      }
      for (var c = 0; c < nch; c++) {
        final v = _lfo(_f32(_offsets[c] + _phase));
        final d = _cur;
        final r = (((v + 1) * 0.5 * d - d) + (_pos - j)) + j;
        var rf = _f32(r);
        if (r < 0) {
          rf = _f32(rf + n);
        } else if (rf >= n) {
          rf = _f32(rf - n);
        }
        var r1 = _f32(rf + 1);
        if (r1 < 0) {
          r1 = _f32(r1 + n);
        } else if (r1 >= n) {
          r1 = _f32(r1 - n);
        }
        final i0 = rf.truncate(), i1 = r1.truncate();
        final fr = _f32(rf - i0);
        final s0 = _line[(i0 % n) * 2 + c], s1 = _line[(i1 % n) * 2 + c];
        final a = _f32(_f32(s0 * (1 / 16384)) * _f32(1 - fr));
        final b = _f32(_f32(s1 * (1 / 16384)) * fr);
        final dry = _f32(buf[i * 2 + c] * _dry);
        buf[i * 2 + c] = _f32(_f32(_f32(a + b) * _w[c]) + dry);
      }
      if (mono) buf[i * 2 + 1] = buf[i * 2];
      _quiet = loud ? 0 : _quiet + 1;
      _step();
    }
    return mono;
  }
}
