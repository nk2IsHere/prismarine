import 'dart:typed_data';

import 'dsp.dart';

/// The channel mix, with the output grouping (0) and the gain in dB of
/// channel n at 1 + n. Groupings 0 and 4 scale each channel of the buffer
/// by its gain, where −80 dB is silence, and keep the channel count.
/// Grouping 6 sends all to the LFE and leaves a stereo or mono input
/// silent. Other groupings act as grouping 0. A gain change ramps linearly
/// over the 64 samples from the start of its block.
class ChannelMix extends Dsp {
  ChannelMix() : super(List.filled(33, 0)) {
    start();
  }

  /// The linear gains of the channels now and their targets.
  final _g = Float64List(32), _to = Float64List(32), _from = Float64List(32);
  bool _ramp = false;

  /// The samples of the current ramp that are done. A ramp spans blocks
  /// that are shorter than 64 frames.
  int _done = 0;

  /// The grouping is one that acts as grouping 0.
  bool get regroups {
    final g = params[0].round();
    return g != 0 && g != 4 && g != 6;
  }

  @override
  void changed(int index) {
    if (index == 0) return;
    _to[index - 1] = params[0].round() == 6 ? 0 : dbGain(params[index]);
    _from.setAll(0, _g);
    _ramp = true;
    _done = 0;
  }

  @override
  void start() {
    for (var c = 0; c < 32; c++) {
      _to[c] = params[0].round() == 6 ? 0 : dbGain(params[c + 1]);
    }
    _g.setAll(0, _to);
    _ramp = false;
  }

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    if (mono) {
      // A mono signal held in both channels is channel 0 alone.
      _run(buf, frames, 2, dual: true);
    } else {
      _run(buf, frames, 2);
    }
    return mono;
  }

  @override
  bool process51(Float32List buf, int frames) {
    _run(buf, frames, 6);
    return true;
  }

  void _run(Float32List buf, int frames, int ch, {bool dual = false}) {
    var i = 0;
    if (_ramp) {
      for (; i < frames && _done < 64; i++, _done++) {
        final t = _done / 64;
        for (var c = 0; c < ch; c++) {
          final k = dual ? 0 : c;
          buf[i * ch + c] *= _from[k] + (_to[k] - _from[k]) * t;
        }
      }
      if (_done >= 64) {
        _g.setAll(0, _to);
        _ramp = false;
      }
    }
    for (var c = 0; c < ch; c++) {
      final g = _g[dual ? 0 : c];
      if (g == 1) continue;
      for (var j = i; j < frames; j++) {
        buf[j * ch + c] *= g;
      }
    }
  }
}

/// The object panner. It passes its input to an object mixer of the output,
/// and the engine has none, so its output is silence.
class ObjectPan extends Dsp {
  ObjectPan() : super([0, 0, 1, 20, 0, 0, 0, 0, 1]);

  @override
  bool process(Float32List buf, int frames, {bool mono = false}) {
    buf.fillRange(0, frames * 2, 0);
    return mono;
  }

  @override
  bool process51(Float32List buf, int frames) {
    buf.fillRange(0, frames * 6, 0);
    return true;
  }
}
