import '../model/model.dart';

/// A playing snapshot: its entries pull mixer properties toward their values
/// by its intensity.
class MixStateInstance {
  MixStateInstance(this.def, this.order) {
    for (final p in def.parameters) {
      _params[p.name.toLowerCase()] = (p, p.defaultValue);
    }
    final s = def.mixState ?? MixStateDef();
    priority = s.priority;
    master = s.intensity;
    _intensity = s.intensityProperty;
    entries = [for (final e in s.entries) (e.target, e.property, e.value)];
    automation = [for (final e in s.entries) e.automation];
  }

  final EventDef def;

  /// Start order (ties in priority apply in it).
  final int order;
  late final int priority;
  late final double master;
  late final List<(String target, int property, double value)> entries;

  /// Each entry's automated value, by its snapshot parameters (null: the
  /// stored value): S2's mix events drive their nested snapshots so, the
  /// "Snap Reverb" at −80 dB puts a reverb send at −80 dB where the entry
  /// stores 0 [ORACLE fmod109 the tunnels' fight music with
  /// MIXEvent_MUS and the cave reverb, data/evidence/audio201].
  late final List<PropertyDef?> automation;

  /// Entry [i]'s value now: its automation at the snapshot's parameters
  /// (as EventInstance automates a property), else the stored value.
  double entryValue(int i) {
    final p = automation[i];
    if (p == null) return entries[i].$3;
    double? r;
    for (final a in p.automation) {
      final ui = a.curve.at(_input(a));
      final v = p.mapping?.map(ui) ?? ui;
      r = r == null
          ? v
          : p.isVolume
          ? r + v
          : v;
    }
    return r!;
  }

  double _input(AutomationDef a) {
    for (final (p, v) in _params.values) {
      if (p.guid == a.parameterGuid) return v;
    }
    return _params[a.parameterName?.toLowerCase()]?.$2 ?? 0;
  }

  PropertyDef? _intensity;
  final _params = <String, (ParameterDef, double)>{};
  bool stopped = false;

  /// Started by an event instrument: its snapshot intensity (0..1).
  double scale = 1;

  String get path => def.path ?? def.guid;

  bool setParameter(String name, double value) {
    final p = _params[name.toLowerCase()];
    if (p == null) return false;
    _params[name.toLowerCase()] = (
      p.$1,
      value.clamp(p.$1.minimum, p.$1.maximum).toDouble(),
    );
    return true;
  }

  /// A parameter by GUID (an event instrument's stub); false when the
  /// snapshot lacks it.
  bool setParameterGuid(String guid, double value) {
    for (final MapEntry(:key, value: (p, _)) in _params.entries) {
      if (p.guid != guid) continue;
      _params[key] = (p, value.clamp(p.minimum, p.maximum).toDouble());
      return true;
    }
    return false;
  }

  /// Its automatic parameters from its 3D position (an event instrument's:
  /// its event's): distance (type 1) and cone angle (type 2).
  void setAuto(double distance, double cone) {
    for (final MapEntry(:key, value: (p, _)) in _params.entries.toList()) {
      if (p.kind == ParameterKind.distance) {
        _params[key] = (p, distance.clamp(p.minimum, p.maximum).toDouble());
      } else if (p.kind == ParameterKind.cone) {
        _params[key] = (p, cone.clamp(p.minimum, p.maximum).toDouble());
      }
    }
  }

  void stop() => stopped = true;

  /// 0..1: the intensity property's curve at its parameter (1 without one),
  /// times the snapshot's own intensity.
  double get intensity {
    final p = _intensity;
    var v = 1.0;
    if (p != null && p.automation.isNotEmpty) {
      final a = p.automation.first;
      final x =
          _params[a.parameterName?.toLowerCase()]?.$2 ??
          _params.values.firstOrNull?.$2 ??
          0;
      v = a.curve.at(x);
    }
    return (v * master * scale).clamp(0.0, 1.0).toDouble();
  }
}
