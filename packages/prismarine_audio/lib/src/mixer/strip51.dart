part of 'strip.dart';

/// A [BusStrip] in 5.1, six channels interleaved in the order FL FR C LFE SL
/// SR. [MixerGraph] folds a 5.1 master to stereo.
extension _Strip51 on BusStrip {
  void _begin51(int frames) {
    if (input51.length != frames * 6) {
      input51 = Float32List(frames * 6);
    } else {
      input51.fillRange(0, input51.length, 0);
    }
  }

  void _add51(Float32List buf, int frames) {
    if (!_wide) {
      // A strip that runs in stereo takes a 5.1 signal folded to stereo.
      add(downmix51(buf, frames), frames);
      return;
    }
    for (var i = 0; i < frames * 6; i++) {
      input51[i] += buf[i];
    }
  }

  /// Adds the stereo input of sources and stereo buses into the 5.1 sum,
  /// L into FL and R into FR.
  void _spread(int frames) {
    for (var i = 0; i < frames; i++) {
      input51[i * 6] += input[i * 2];
      input51[i * 6 + 1] += input[i * 2 + 1];
    }
  }

  void _process51(int frames, PropertyValue prop, StripSink sink) {
    if (_wide) {
      if (input51.length != frames * 6) _begin51(frames);
      _spread(frames);
    }
    if (output.length != frames * 6) output = Float32List(frames * 6);
    var inPeak = 0.0;
    final src = _wide ? input51 : input;
    for (var i = 0; i < src.length && i < frames * 6; i++) {
      final a = src[i].abs();
      if (a > inPeak) inPeak = a;
    }
    if (inPeak == 0 && _lastPeak < 1e-7 && !_keyed) {
      for (final st in _stages) {
        switch (st) {
          case _Fader():
            _gain = dbGain(prop(guid, 0) ?? def.volume);
          case _Effect(:final dsp):
            dsp.idle(frames);
          case _Send() || _Tap():
        }
      }
      output.fillRange(0, frames * 6, 0);
      outputMono = false;
      _endPeak = 0;
      return;
    }
    // The chain runs in stereo up to a surround PAN, in 5.1 from there.
    var ch = _wide ? 6 : 2;
    var m = !_wide && mono;
    var buf = output;
    if (_wide) {
      output.setRange(0, frames * 6, input51);
    } else {
      buf = Float32List.fromList(input.sublist(0, frames * 2));
    }
    for (final s in _stages) {
      switch (s) {
        case _Fader():
          final g = dbGain(prop(guid, 0) ?? def.volume);
          final g0 = _gain ?? g;
          _gain = g;
          final e0 = faderFrom, e1 = faderTo;
          for (var i = 0; i < frames; i++) {
            final k =
                (g0 + (g - g0) * (i / frames)) *
                (e0 + (e1 - e0) * (i / frames));
            for (var c = 0; c < ch; c++) {
              buf[i * ch + c] *= k;
            }
          }
        case _Effect(:final guid, :final dsp, :final label):
          for (var i = 0; i < dsp.params.length; i++) {
            if (prop(guid, 1000 + i) case final v?) dsp.set(i, v);
          }
          if (ch == 6) {
            if (!dsp.process51(buf, frames)) {
              _problem?.call('no 5.1 form of effect $label');
            }
          } else if (dsp is Pan && dsp.surround) {
            dsp.toSurround(buf, m, output, frames);
            buf = output;
            ch = 6;
            m = false;
          } else {
            m = dsp.process(buf, frames, mono: m);
          }
        case _Send(
          :final guid,
          :final returnBus,
          :final returnPath,
          :final level,
        ):
          final g = dbGain(prop(guid, 0) ?? level);
          if (g == 0) break;
          final b = Float32List(frames * ch);
          for (var i = 0; i < frames * ch; i++) {
            b[i] = buf[i] * g;
          }
          sink.send(returnBus, returnPath, b, m, channels: ch);
        case _Tap(:final targets, :final label):
          if (ch == 6) {
            _problem?.call('no 5.1 form of effect $label');
            break;
          }
          sink.sidechain(
            targets,
            Float32List.fromList(buf.sublist(0, frames * 2)),
          );
      }
    }
    if (ch == 2) {
      // A surround pan that did not run spreads stereo onto 5.1, and mono at
      // the upmix gain.
      final k = m ? upmixGain : 1.0;
      for (var i = 0; i < frames; i++) {
        output[i * 6] = buf[i * 2] * k;
        output[i * 6 + 1] = buf[i * 2 + 1] * k;
        for (var c = 2; c < 6; c++) {
          output[i * 6 + c] = 0;
        }
      }
    }
    outputMono = false;
    var outPeak = 0.0, endPeak = 0.0;
    final end = math.max(0, frames - 64) * 6;
    for (var i = 0; i < frames * 6; i++) {
      final a = output[i].abs();
      if (a > outPeak) outPeak = a;
      if (i >= end && a > endPeak) endPeak = a;
    }
    _lastPeak = outPeak;
    _endPeak = endPeak;
  }
}

/// Folds the 5.1 [buf] to stereo as L = FL + C/√2 + SL/√2 and
/// R = FR + C/√2 + SR/√2, without the LFE.
Float32List downmix51(Float32List buf, int frames, [Float32List? out]) {
  final o = out ?? Float32List(frames * 2);
  const k = Surround.downmix;
  for (var i = 0; i < frames; i++) {
    final c = buf[i * 6 + 2] * k;
    o[i * 2] = buf[i * 6] + c + buf[i * 6 + 4] * k;
    o[i * 2 + 1] = buf[i * 6 + 1] + c + buf[i * 6 + 5] * k;
  }
  return o;
}
