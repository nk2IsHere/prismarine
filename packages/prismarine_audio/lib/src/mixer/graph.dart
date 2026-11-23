import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_math/libm.dart' as libm;
import '../model/model.dart';
import 'dsp.dart';
import 'dsp_dynamics.dart';
import 'mix_state.dart';
import 'strip.dart';

/// The mixer, buses with their effect chains, sends into returns and
/// sidechain taps into compressors, with mix states over bus volumes, send
/// levels and effect parameters. It renders children before parents,
/// sidechain sources before their targets and senders before returns.
class MixerGraph implements StripSink {
  MixerGraph(MixerDef mixer, {this.log}) {
    final paths = mixer.paths;
    for (final def in mixer.buses) {
      final s = BusStrip(def, problem: problem);
      _byGuid[def.guid] = s;
      if (paths[def.guid] case final p?) _byPath[p] = s;
      if (def.master && master == null) {
        master = s;
        _masterPath = paths[def.guid];
      }
      for (final (fx, c) in s.compressors) {
        _compressors[fx] = (s, c);
      }
      _base[(def.guid, 0)] = def.volume;
      for (final fx in def.effects) {
        final g = fx.guid;
        if (fx is SendEffect) {
          _base[(g, 0)] = fx.level;
          _volumeType.add(g);
        }
        if (fx is! DspEffect) continue;
        for (final (i, p) in fx.params.indexed) {
          if (p.stored case final v?) _base[(g, 1000 + i)] = v;
          if (_gainParams[fx.kind]?.contains(i) ?? false) {
            _gainType.add((g, 1000 + i));
          }
        }
      }
      _volumeType.add(def.guid);
    }
    _order = _sort();
  }

  final void Function(String message)? log;
  final _byGuid = <String, BusStrip>{}, _byPath = <String, BusStrip>{};
  final _compressors = <String, (BusStrip, Compressor)>{};
  final _base = <(String, int), double>{};
  final _volumeType = <String>{};
  final _gainType = <(String, int)>{};

  /// The dB parameters of each effect kind, which a mix state blends in
  /// linear gain like a volume. They are the gains of the three-band EQ, the
  /// ceiling and maximizer of the limiter, the threshold and make-up of the
  /// compressor, the low shelf, wet and dry levels of the reverb, the gains
  /// of the channel mix and the band gains of the multiband EQ.
  static const _gainParams = {
    EffectKind.limiter: {1, 2},
    EffectKind.compressor: {0, 4},
    EffectKind.reverb: {8, 11, 12},
    EffectKind.threeBandEq: {0, 1, 2},
    EffectKind.channelMix: {
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, //
      19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    },
    EffectKind.multibandEq: {3, 7, 11, 15, 19},
  };
  late final List<BusStrip> _order;
  BusStrip? master;

  /// The path of the master bus, null without one.
  String? get masterPath => _masterPath;
  String? _masterPath;
  final problems = <String>{};

  final _snapshotDefs = <String, EventDef>{};
  final _active = <MixStateInstance>[];
  int _started = 0;

  void problem(String m) {
    if (problems.add(m)) log?.call(m);
  }

  BusStrip? bus(String path) => _byPath[path];
  BusStrip? busByGuid(String guid) => _byGuid[guid];
  Iterable<BusStrip> get buses => _byGuid.values;

  /// Makes the mix states in [defs] startable by path.
  void addMixStates(Iterable<EventDef> defs) {
    for (final d in defs) {
      // The first definition of a path wins.
      if (d.isMixState && d.path != null) {
        _snapshotDefs.putIfAbsent(d.path!, () => d);
      }
    }
  }

  MixStateInstance? startMixState(String path) {
    final d = _snapshotDefs[path];
    if (d == null) {
      problem('unknown snapshot $path');
      return null;
    }
    return startMixStateDef(d);
  }

  /// Starts a mix state instance of [d], for a mix state instrument.
  MixStateInstance startMixStateDef(EventDef d) {
    final s = MixStateInstance(d, _started++);
    _active.add(s);
    return s;
  }

  List<MixStateInstance> get snapshots => List.unmodifiable(_active);

  /// Renders [inputs], stereo by bus path, and [inputs51], 5.1 by bus path,
  /// through the graph. Returns the stereo output of the master. A 5.1
  /// master is folded to stereo.
  Float32List render(
    Map<String, Float32List> inputs,
    int frames, {
    Map<String, Float32List> inputs51 = const {},
  }) {
    _active.removeWhere((s) => s.stopped);
    _active.sort((a, b) {
      final c = a.priority.compareTo(b.priority);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    _resolved.clear();
    for (final s in _byGuid.values) {
      s.begin(frames);
    }
    for (final MapEntry(key: path, value: buf) in inputs.entries) {
      final s = _byPath[path];
      if (s == null) problem('no mixer bus $path (into the master)');
      (s ?? master)?.add(buf, frames);
    }
    for (final MapEntry(key: path, value: buf) in inputs51.entries) {
      final s = _byPath[path];
      if (s == null) problem('no mixer bus $path (into the master)');
      (s ?? master)?.add(buf, frames, srcCh: 6);
    }
    for (final s in _order) {
      s.process(frames, _prop, this);
      final parent = _byGuid[s.def.output];
      parent?.add(
        s.output,
        frames,
        srcMono: s.outputMono,
        srcCh: s.outputChannels,
      );
    }
    final m = master;
    if (m == null) return Float32List(frames * 2);
    if (m.outputChannels == 6) return downmix51(m.output, frames);
    if (m.outputMono) {
      for (var i = 0; i < frames * 2; i++) {
        m.output[i] *= upmixGain;
      }
    }
    return m.output;
  }

  final _resolved = <(String, int), double?>{};

  /// Returns the value of a property under the mix states, lowest priority
  /// first. Each pulls the value toward its entry by its intensity, volumes
  /// and dB effect parameters in linear gain and other properties linearly.
  /// A property that no mix state touches returns to its stored value.
  double? _prop(String owner, int index) =>
      _resolved.putIfAbsent((owner, index), () {
        double? v;
        for (final s in _active) {
          final k = s.intensity;
          if (k <= 0) continue;
          for (final (i, (t, p, _)) in s.entries.indexed) {
            if (t != owner || p != index) continue;
            final value = s.entryValue(i);
            final from = v ?? _base[(owner, index)] ?? value;
            if ((index == 0 && _volumeType.contains(owner)) ||
                _gainType.contains((owner, index))) {
              final g = dbGain(from) + (dbGain(value) - dbGain(from)) * k;
              v = g <= 0 ? -80 : 20 * libm.log(g) / math.ln10;
            } else {
              v = from + (value - from) * k;
            }
          }
        }
        return v ?? _base[(owner, index)];
      });

  @override
  void send(
    String returnBus,
    String? returnPath,
    Float32List buf,
    bool mono, {
    int channels = 2,
  }) {
    final r =
        _byGuid[returnBus] ?? (returnPath == null ? null : _byPath[returnPath]);
    if (r == null) {
      problem('send to unknown return $returnBus');
      return;
    }
    r.add(buf, buf.length ~/ channels, srcMono: mono, srcCh: channels);
  }

  @override
  void sidechain(List<String> targets, Float32List buf) {
    for (final t in targets) {
      final c = _compressors[t]?.$2;
      if (c == null) continue;
      final cur = c.sidechain;
      if (cur == null) {
        c.sidechain = buf;
      } else {
        for (var i = 0; i < cur.length && i < buf.length; i++) {
          cur[i] += buf[i];
        }
      }
    }
  }

  /// Returns the buses in Kahn's order, children before parents, senders
  /// before returns and sidechain sources before the buses of their
  /// compressors.
  List<BusStrip> _sort() {
    final after = <BusStrip, Set<BusStrip>>{
      for (final s in _byGuid.values) s: {},
    };
    final need = <BusStrip, int>{for (final s in _byGuid.values) s: 0};
    void edge(BusStrip a, BusStrip? b) {
      if (b == null || a == b) return;
      if (after[a]!.add(b)) need[b] = need[b]! + 1;
    }

    for (final s in _byGuid.values) {
      edge(s, _byGuid[s.def.output]);
      for (final fx in s.def.effects) {
        switch (fx) {
          case SendEffect(:final returnBus):
            edge(s, _byGuid[returnBus]);
          case SidechainTap(:final targets):
            for (final t in targets) {
              edge(s, _compressors[t]?.$1);
            }
          case DspEffect():
        }
      }
    }
    final ready = [
      for (final s in _byGuid.values)
        if (need[s] == 0) s,
    ];
    final out = <BusStrip>[];
    while (ready.isNotEmpty) {
      final s = ready.removeAt(0);
      out.add(s);
      for (final b in after[s]!) {
        need[b] = need[b]! - 1;
        if (need[b] == 0) ready.add(b);
      }
    }
    if (out.length < _byGuid.length) {
      problem(
        'mixer graph has a cycle; ${_byGuid.length - out.length} buses run late',
      );
      out.addAll(_byGuid.values.where((s) => !out.contains(s)));
    }
    return out;
  }
}
