import '../model/model.dart';

/// A playing mix state. Its entries pull properties of the mixer toward
/// their values by its intensity.
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

  /// The start order, which orders mix states of the same priority.
  final int order;
  late final int priority;
  late final double master;
  late final List<(String target, int property, double value)> entries;

  /// The automation of each entry at the parameters of the mix state, null
  /// for an entry with its stored value.
  late final List<PropertyDef?> automation;

  /// Returns the value of entry [i] now, its automation at the parameters of
  /// the mix state, else its stored value.
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

  /// The intensity of a mix state instrument that started it, 0 to 1.
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

  /// Sets a parameter by id, for the stub of an instrument. Returns false
  /// when the mix state lacks it.
  bool setParameterGuid(String guid, double value) {
    for (final MapEntry(:key, value: (p, _)) in _params.entries) {
      if (p.guid != guid) continue;
      _params[key] = (p, value.clamp(p.minimum, p.maximum).toDouble());
      return true;
    }
    return false;
  }

  /// Sets the distance and cone parameters from the position of the event
  /// that plays its instrument.
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

  /// The intensity from 0 to 1, the curve of the intensity property at its
  /// parameter, or 1 without one, times the intensity of the mix state.
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
