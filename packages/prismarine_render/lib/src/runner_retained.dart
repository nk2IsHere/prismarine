part of 'frame_runner.dart';

/// The retained passes (FramePlan.retained) with the stamp of the last run of
/// each, by pass name. A pass whose stamp is the one of its last run, on
/// targets not made again since, is left out. Its targets hold what it would
/// write. A plan that did not run, since a newer one took its place, leaves its
/// stamps unrun. The passes of the next plan then run. `PRISMARINE_RETAIN=off`
/// runs every pass.
final class _Retained {
  final _ran = <String, int>{};
  int _gen = -1;
  Map<String, int> _now = const {};
  static final _off = envVar('RETAIN') == 'off';

  /// The number of passes that the last run left out.
  int left = 0;

  /// Starts a run of [plan] on targets of the generation [gen]
  /// (FrameRunner._texGen). Any target made again forgets every stamp.
  void begin(FramePlan plan, int gen) {
    _now = _off ? const {} : plan.retained;
    left = 0;
    if (_gen != gen) {
      _ran.clear();
      _gen = gen;
    }
  }

  /// Returns true when [p] is left out of this run. A pass that runs is
  /// noted.
  bool leaves(PassPlan p) {
    if (_now.isEmpty) return false;
    final stamp = _now[p.name];
    if (stamp == null) return false;
    if (stamp != 0 && _ran[p.name] == stamp) {
      left++;
      return true;
    }
    _ran[p.name] = stamp;
    return false;
  }
}
