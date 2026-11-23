import '../model/model.dart';

/// The channel formats an S2 event's strips run in (1 mono, 2 stereo, 6
/// 5.1), by bus GUID; strips not listed follow their layout (2 mono, else
/// stereo), as all of S1's do.
///
/// A strip whose layout is 5.1 runs in the widest format of what feeds it:
/// its instruments' waveforms and the strips under it, so a mono source
/// keeps to mono up to its strip's surround PAN [O: `sfx_idle_chicken_multi
/// _1_3d`: mono spawns on 5.1-layout tracks leave their surround PANs on all
/// five speakers alike, as a mono input does]; and any strip a 5.1 signal
/// reaches (a surround-panned strip under it) runs in 5.1.
extension EventFormats on EventDef {
  Map<String, int> get stripFormats => _formats[this] ??= _compute(this);
}

final _formats = Expando<Map<String, int>>();

/// A PAN effect in surround mode with a 5.1 target (its output is 5.1).
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

/// A 5.1 (6) or quad (4) layout: a quad strip runs as 5.1 with its four
/// channels on FL FR SL SR [ORACLE fmod109 `AMB_Cave_CreakyDirty`'s
/// master capture: FL, FR, SL and SR only].
bool _wide(StripDef b) =>
    b.layout == ChannelLayout.surround51 || b.layout == ChannelLayout.quad;

/// Strip [b] ends in 5.1: it runs in 5.1 ([format] 6) or has a surround PAN.
bool ends51(StripDef b, [int? format]) =>
    format == 6 || b.effects.any(surroundPan);
