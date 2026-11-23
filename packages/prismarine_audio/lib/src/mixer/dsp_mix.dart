import 'dart:typed_data';

import 'dsp.dart';

/// FMOD_DSP_TYPE_CHANNELMIX (33, FMOD 1.09): output grouping (0), then a
/// gain in dB for channel n at 1 + n. S2's Master Bank puts one on six 5.1
/// buses, grouping 4 (all 5.1). Measured with S2's fmod64.dll [O: the
/// fmod-runtime.md section "FMOD 1.09 (S2)"]:
///
/// - groupings 0 and 4 scale each channel of the buffer by its gain
///   (−80 dB is silence) and keep the channel count; grouping 6 (all LFE)
///   leaves a stereo or mono input silent;
/// - a gain change ramps linearly over the 64 samples from the start of
///   the block it lands in.
/// Other groupings (unused by S2) pass the signal as grouping 0 does.
class ChannelMix extends Dsp {
  ChannelMix() : super(List.filled(33, 0)) {
    start();
  }

  /// The gains now (per channel, linear) and their targets.
  final _g = Float64List(32), _to = Float64List(32), _from = Float64List(32);
  bool _ramp = false;

  /// Samples of the current ramp done (a ramp spans our blocks if they are
  /// shorter than 64 frames).
  int _done = 0;

  /// The grouping is one this mixer doesn't regroup by.
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
      // A mono signal held dual-mono is FMOD's one channel: channel 0.
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

/// FMOD_DSP_TYPE_OBJECTPAN (35, FMOD 1.09): it hands its input to the
/// output's object mixer, and an output without objects (S2's PC build has
/// none in FMOD 1.09.04) hears nothing of it [O: FMOD 1.09, `AMB Crowd
/// Walla_Murmur_Dist` renders silent at every position and sounds with its
/// object panner bypassed; the low-level DSP alone is silent too]. S2 puts
/// one on 7 Ep205 crowd events.
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
