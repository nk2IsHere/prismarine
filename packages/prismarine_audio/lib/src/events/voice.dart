import 'dart:typed_data';

import '../pcm_source.dart';

/// Reads [source] at a fractional frame position with linear interpolation
/// (FMOD's default resampler) into stereo frames; mono plays dual-mono. A
/// source of four or more channels (quad: FL FR SL SR) adds its third and
/// fourth into [addInto]'s `rear`, a 5.1 buffer's SL and SR, when given.
class SourceReader {
  SourceReader(this.source);
  final PcmSource source;
  Float32List _chunk = Float32List(0);
  final _one = Float32List(16);

  /// Adds [n] frames into [out] (stereo, interleaved) from frame [at], reading
  /// the source from [pos] in steps of [rate] source frames, with gain ramping
  /// [g0] → [g1], times per-frame [gains] when given. [loop] wraps at the
  /// source's end. Returns the position after the last frame, or null once the
  /// source has ended.
  double? addInto(
    Float32List out,
    int at,
    int n,
    double pos,
    double rate, {
    double g0 = 1,
    double g1 = 1,
    Float32List? gains,
    bool loop = false,
    bool downmix = false,
    double panL = 1,
    double panR = 1,
    Float32List? rear,
  }) {
    final frames = source.frames;
    if (frames <= 0) return null;
    final ch = source.channels;
    // The source span this call touches, read once. The loop steps pos by
    // rate, which can drift past pos + (n − 1)·rate by an ulp onto the next
    // frame: the span reaches a frame further.
    final first = pos < 0 ? 0 : pos.floor();
    final last = (pos + n * rate).floor() + 1;
    final span = loop ? 0 : (last < frames ? last : frames - 1) - first + 1;
    if (span > 0) {
      if (_chunk.length < span * ch) _chunk = Float32List(span * ch);
      source.read(_chunk, first, span);
    }
    for (var i = 0; i < n; i++) {
      if (pos >= frames) {
        if (!loop) return null;
        pos %= frames;
      }
      if (pos < 0) {
        pos += rate;
        continue;
      }
      final f = pos.floor();
      final frac = pos - f;
      var g = g0 + (g1 - g0) * (i / n);
      if (gains != null) g *= gains[i];
      double l0, r0, l1, r1;
      if (loop) {
        source.read(_one, f, 1);
        l0 = _one[0];
        r0 = ch > 1 ? _one[1] : l0;
        source.read(_one, f + 1 < frames ? f + 1 : 0, 1);
        l1 = _one[0];
        r1 = ch > 1 ? _one[1] : l1;
      } else {
        final k = (f - first) * ch;
        l0 = _chunk[k];
        r0 = ch > 1 ? _chunk[k + 1] : l0;
        if (f + 1 < frames) {
          l1 = _chunk[k + ch];
          r1 = ch > 1 ? _chunk[k + ch + 1] : l1;
        } else {
          l1 = l0;
          r1 = r0;
        }
      }
      final o = (at + i) * 2;
      if (rear != null && ch >= 4) {
        final (sl0, sr0, sl1, sr1) = _rears(loop, f, first, frames, ch);
        rear[(at + i) * 6 + 4] += (sl0 + (sl1 - sl0) * frac) * g * panL;
        rear[(at + i) * 6 + 5] += (sr0 + (sr1 - sr0) * frac) * g * panR;
      }
      var l = (l0 + (l1 - l0) * frac) * g, r = (r0 + (r1 - r0) * frac) * g;
      if (downmix) l = r = (l + r) * 0.7071067811865476;
      out[o] += l * panL;
      out[o + 1] += r * panR;
      pos += rate;
    }
    return pos >= frames && !loop ? null : pos;
  }

  /// Channels 2 and 3 at frame [f] and the next (wrapping when [loop]).
  (double, double, double, double) _rears(
    bool loop,
    int f,
    int first,
    int frames,
    int ch,
  ) {
    if (loop) {
      source.read(_one, f, 1);
      final a = _one[2], b = _one[3];
      source.read(_one, f + 1 < frames ? f + 1 : 0, 1);
      return (a, b, _one[2], _one[3]);
    }
    final k = (f - first) * ch;
    if (f + 1 < frames) {
      return (
        _chunk[k + 2],
        _chunk[k + 3],
        _chunk[k + ch + 2],
        _chunk[k + ch + 3],
      );
    }
    return (_chunk[k + 2], _chunk[k + 3], _chunk[k + 2], _chunk[k + 3]);
  }
}
