import 'dart:typed_data';

import '../plan/frame_plan.dart';

/// A pass's rows kept from frame to frame, by pass name: the last set's id
/// and plan lists, bounds and culling values again while they hold the
/// same, and the set itself when all do (perf: a pass's rows copied each
/// frame; the plan writer skips a set whose lists it sent last).
RowSet keptRowSet(
  String pass,
  List<int> ids,
  List<DrawPlan> plans, {
  Float32List? bounds,
  Float32List? params,
}) => (_keptRows[pass] ??= _KeptRowSet()).take(ids, plans, bounds, params);

final _keptRows = <String, _KeptRowSet>{};

final class _KeptRowSet {
  List<int> _ids = const [];
  List<DrawPlan> _plans = const [];
  Float32List? _bounds, _params;
  RowSet? _set;

  RowSet take(
    List<int> ids,
    List<DrawPlan> plans,
    Float32List? bounds,
    Float32List? params,
  ) {
    var same = true;
    if (!_sameRows(ids, plans)) {
      _ids = List.of(ids, growable: false);
      _plans = List.of(plans, growable: false);
      same = false;
    }
    if (!_sameFloats(_bounds, bounds)) {
      _bounds = bounds == null ? null : Float32List.fromList(bounds);
      same = false;
    }
    if (!_sameFloats(_params, params)) {
      _params = params == null ? null : Float32List.fromList(params);
      same = false;
    }
    final set = _set;
    if (same && set != null) return set;
    return _set = RowSet(_ids, _plans, bounds: _bounds, params: _params);
  }

  bool _sameRows(List<int> ids, List<DrawPlan> plans) {
    final n = ids.length;
    if (n != _ids.length || plans.length != _plans.length) return false;
    for (var i = 0; i < n; i++) {
      if (ids[i] != _ids[i] || !identical(plans[i], _plans[i])) return false;
    }
    return true;
  }

  /// The same bits (a sign of zero counts).
  static bool _sameFloats(Float32List? a, Float32List? b) {
    if (a == null || b == null) return a == b;
    final n = a.length;
    if (n != b.length) return false;
    for (var i = 0; i < n; i++) {
      final x = a[i], y = b[i];
      if (x != y || x.isNegative != y.isNegative) return false;
    }
    return true;
  }
}
