import '../model/model.dart';

/// The channel formats of an event's strips, 1 for mono, 2 for stereo and 6
/// for 5.1, by strip id. A strip that is not listed follows its layout.
///
/// A strip whose layout is 5.1 runs in the widest format of what feeds it,
/// the waveforms of its instruments and the strips under it. A mono source
/// keeps to mono up to the surround pan of its strip. A strip that a 5.1
/// signal reaches, from a surround-panned strip under it, runs in 5.1.
extension EventFormats on EventDef {
  Map<String, int> get stripFormats => _formats[this] ??= _compute(this);
}

final _formats = Expando<Map<String, int>>();

/// The effect is a pan in surround mode with a 5.1 target, whose output is
/// 5.1.
bool surroundPan(EffectDef fx) {
  if (fx is! DspEffect || fx.kind != EffectKind.pan || fx.bypass) {
    return false;
  }
  final ps = fx.params;
  return ps.length > 20 && ps[0].stored == 2 && ps[20].stored == 6;
}

Map<String, int> _compute(EventDef d) {
  final out = <String, int>{};
  final strips = [...d.tracks, ...d.returns, d.masterTrack];

  int sources(StripDef b) {
    var f = 1;
    void inst(InstrumentDef i, String? via) {
      final bus = i.outputBus ?? via ?? d.masterTrack.guid;
      if (bus != b.guid) return;
      final w = i.waveform;
      if (w != null && w.channels > f) f = w.channels >= 4 ? 6 : 2;
      for (final (_, e) in i.entries) {
        inst(e, bus);
      }
      if (i.kind == 'event' && i.nested != null && f < 2) f = 2;
    }

    for (final p in d.timeline.placements) {
      inst(p.instrument, null);
    }
    for (final pa in d.parameters) {
      for (final sp in pa.instruments) {
        inst(sp.instrument, null);
      }
    }
    for (final t in strips) {
      if (t.output != b.guid || identical(t, b)) continue;
      final g = ends51(t) ? 6 : (_wide(t) ? sources(t) : 2);
      if (g > f) f = g;
    }
    return f;
  }

  for (final b in strips) {
    if (_wide(b)) out[b.guid] = sources(b);
  }
  // A strip under which a strip ends in 5.1 runs in 5.1.
  for (final t in [...d.tracks, ...d.returns]) {
    if (!ends51(t, out[t.guid])) continue;
    final to = strips.any((s) => s.guid == t.output)
        ? t.output!
        : d.masterTrack.guid;
    out[to] = 6;
  }
  if (d.inputBus case final ib?) {
    if (ends51(d.masterTrack, out[d.masterTrack.guid])) out[ib.guid] = 6;
  }
  return out;
}

/// The layout is 5.1 or quad. A quad strip runs as 5.1 with its four
/// channels on FL FR SL SR.
bool _wide(StripDef b) =>
    b.layout == ChannelLayout.surround51 || b.layout == ChannelLayout.quad;

/// Strip [b] ends in 5.1. It runs in 5.1, with [format] 6, or has a surround
/// pan.
bool ends51(StripDef b, [int? format]) =>
    format == 6 || b.effects.any(surroundPan);
