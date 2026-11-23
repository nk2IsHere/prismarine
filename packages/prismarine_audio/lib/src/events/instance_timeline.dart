part of 'instance.dart';

extension _EventTimeline on EventInstance {
  /// Advances the cursor over [frames]. Loop regions, transition markers and
  /// quantized transition regions jump it. Timelocked instruments render
  /// from its position and the others start when it enters them.
  void _timeline(int frames) {
    final tl = def.timeline;
    // A timelocked instrument at the cursor whose data is still loading
    // holds the timeline.
    for (final (k, p) in tl.placements.indexed) {
      if (!p.timelocked || cursor < p.start || cursor >= p.end) continue;
      final s = _locked[k] ??= _lock(p);
      if (s != null && !pcmReady(s.reader.source)) return;
    }
    _evaluateRegions();
    var f = 0;
    var jumps = 0;
    var arrived = true;
    while (f < frames) {
      final c = cursor;
      if (c >= tl.length && _pending == null) {
        _enterAsync(c, 0, f, arrived);
        break;
      }
      var m = frames - f;
      int? jumpAt, dest;
      void consider(int offset, int to) {
        if (offset >= 0 &&
            offset <= m &&
            (jumpAt == null || offset < jumpAt!)) {
          jumpAt = offset;
          dest = to;
        }
      }

      if (jumps < 8) {
        for (final t in tl.transitions) {
          if (t.isLoop) {
            if (c < t.end &&
                t.end <= c + m &&
                _holds(t.conditionParameter, t.conditionMin, t.conditionMax)) {
              consider(t.end - c, t.destination);
            }
          } else if (t.isMarker) {
            if (t.start >= c &&
                t.start < c + m &&
                !(arrived && jumps > 0 && t.start == c) &&
                _holds(t.conditionParameter, t.conditionMin, t.conditionMax)) {
              consider(t.start - c, t.destination);
            }
          }
        }
        if (_pending case (final t, final at)) {
          if (at >= c && at < c + m) consider(at - c, t.destination);
        }
      }
      if (c + m > tl.length && jumpAt == null) m = tl.length - c;
      final run = jumpAt ?? m;
      _enterAsync(c, run, f, arrived);
      _renderLocked(c, run, f);
      f += run;
      if (jumpAt != null) {
        _leaveAsync(c + run, dest!);
        cursor = dest!;
        if (_pending?.$1.destination == dest) _pending = null;
        jumps++;
        arrived = true;
      } else {
        cursor = c + run;
        arrived = false;
        if (run == 0) break;
      }
    }
    // The instruments that are not timelocked that the cursor ran past.
    for (final (k, p) in tl.placements.indexed) {
      if (!p.timelocked &&
          _asyncInside[k] &&
          !(cursor >= p.start && cursor < p.end)) {
        _asyncInside[k] = false;
        _cut(p);
      }
    }
  }

  /// Latches a quantized transition when its region holds the cursor and its
  /// condition holds. Drops it when the condition stops holding.
  void _evaluateRegions() {
    final c = cursor;
    if (_pending case (final t, _)) {
      if (!_holds(t.conditionParameter, t.conditionMin, t.conditionMax)) {
        _pending = null;
      }
    }
    if (_pending != null) return;
    for (final t in def.timeline.transitions) {
      if (t.isLoop || t.isMarker) continue;
      if (c < t.start || c >= t.end) continue;
      if (!_holds(t.conditionParameter, t.conditionMin, t.conditionMax)) {
        continue;
      }
      final at = t.unit == 0 ? c : _grid(t, c + transitionLookahead);
      if (at < t.end) {
        _pending = (t, at);
        return;
      }
    }
  }

  /// Returns the first quantization point of [t] at or after [x].
  int _grid(TransitionDef t, double x) {
    final markers = def.timeline.tempo;
    final m = markers.lastWhere(
      (m) => m.position <= x,
      orElse: () =>
          markers.isEmpty ? EventInstance._defaultTempo : markers.first,
    );
    final quarter = 60 / m.tempo * timelineRate;
    final unit = switch (t.unit) {
      1 => quarter * 4 / m.beatUnit * m.beatsPerBar,
      2 => quarter / 2,
      _ => quarter,
    };
    final step = unit * math.max(1, t.multiplier);
    final k = ((x - m.position) / step - 1e-9).ceil();
    return (m.position + k * step).round();
  }

  void _enterAsync(int c, int run, int at, bool arrived) {
    for (final (k, p) in def.timeline.placements.indexed) {
      if (p.timelocked) continue;
      final inside = c >= p.start && c < p.end;
      if (inside && !_asyncInside[k]) {
        _asyncInside[k] = true;
        _trigger(p.instrument, at, owner: p);
      } else if (!inside && p.start > c && p.start < c + run) {
        _asyncInside[k] = true;
        _trigger(p.instrument, at + p.start - c, owner: p);
      }
    }
  }

  /// Jumps from [from] to [to]. The instruments that are not timelocked and
  /// that the jump leaves are cut with cutoff and they are armed again.
  void _leaveAsync(int from, int to) {
    for (final (k, p) in def.timeline.placements.indexed) {
      if (p.timelocked || !_asyncInside[k]) continue;
      if (to >= p.start && to < p.end && from <= p.end) continue;
      _asyncInside[k] = false;
      _cut(p);
    }
  }

  /// Renders the timelocked instruments over the timeline from [c] to
  /// [c] + [run] at block frame [at]. Each plays from its position in its
  /// box, its waveform repeating, cut at the end of the box.
  void _renderLocked(int c, int run, int at) {
    if (run <= 0) return;
    for (final (k, p) in def.timeline.placements.indexed) {
      if (!p.timelocked) continue;
      final lo = math.max(c, p.start), hi = math.min(c + run, p.end);
      if (lo >= hi) {
        if (c >= p.end || c + run <= p.start) _locked[k] = null;
        continue;
      }
      final s = _locked[k] ??= _lock(p);
      if (s == null) continue;
      final n = hi - lo;
      Float32List? gains;
      final fade = p.instrument.property(4);
      if (fade != null && fade.automation.isNotEmpty) {
        gains = Float32List(n);
        for (var i = 0; i < n; i++) {
          final x = (lo + i).toDouble();
          gains[i] = _automated(fade, (a) => a.onTimeline ? x : _input(a))!;
        }
      }
      final (fk, down) = _format(s.reader.source, s.bus);
      final rear = s.bus.wide && s.reader.source.channels >= 4
          ? s.bus.input51
          : null;
      // With Placement.fill the waveform repeats to fill its box without a
      // gap, also when its loop count is 0.
      final len = s.reader.source.frames;
      var pos = (lo - p.start) * s.rate + s.seek;
      var done = 0;
      while (done < n) {
        var m = n - done;
        if (len > 0) {
          if (pos >= len && !s.fill) break;
          if (pos >= len) pos %= len;
          final fit = ((len - pos) / s.rate).ceil();
          if (fit < m) m = fit;
        }
        s.reader.addInto(
          s.bus.input,
          at + lo - c + done,
          m,
          pos,
          s.rate,
          g0: s.gain * fk,
          g1: s.gain * fk,
          gains: gains == null
              ? null
              : Float32List.sublistView(gains, done, done + m),
          downmix: down,
          rear: rear,
        );
        pos += m * s.rate;
        done += m;
      }
    }
  }

  _Locked? _lock(Placement p) {
    var inst = p.instrument;
    var volume = 0.0, pitch = 0.0;
    if (inst.kind == 'playlist') {
      // A timelocked playlist picks an entry each time its box is entered
      // and plays it as a timelocked sample, with the volume and pitch of
      // the playlist on top.
      volume = inst.volume + _modulation(inst, 0);
      pitch = inst.pitch + _modulation(inst, 1);
      final e = _pick(inst);
      if (e == null) return null;
      inst = e;
    }
    if (inst.kind != 'sample') {
      player.problem('unsupported timelocked ${inst.kind} in ${def.path}');
      return null;
    }
    final w = inst.waveform;
    if (w == null) return null;
    final src = player.sample(w);
    if (src == null) return null;
    pitch += inst.pitch + _modulation(inst, 1);
    volume += _automated(inst.property(0)) ?? inst.volume;
    final gain = dbToGain(volume + _modulation(inst, 0));
    return _Locked(
      SourceReader(src),
      _strips[inst.outputBus] ?? _strips[p.instrument.outputBus] ?? _master,
      src.sampleRate / timelineRate * libm.dpow(2, pitch / 12),
      gain,
      EventInstance._seekFrames(src, _startOffset(inst)) +
          inst.leftTrim * src.sampleRate / timelineRate,
      fill: p.fill,
    );
  }
}
