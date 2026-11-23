part of 'frame_runner.dart';

/// Retained passes (FramePlan.retained): the stamp each such pass last ran
/// with, by pass name. A pass whose stamp is the one it ran with, on
/// targets not made again since, is left out: its targets hold what it
/// would write. A plan never run (a newer one took its place) leaves its
/// stamps unrun, so the next plan's passes run; `PRISMARINE_RETAIN=off` runs
/// every pass.
final class _Retained {
  final _ran = <String, int>{};
  int _gen = -1;
  Map<String, int> _now = const {};
  static final _off = envVar('RETAIN') == 'off';

  /// Passes the last run left out.
  int left = 0;

  /// Starts a run of [plan] on targets of generation [gen]
  /// (FrameRunner._texGen: any target made again forgets every stamp).
  void begin(FramePlan plan, int gen) {
    _now = _off ? const {} : plan.retained;
    left = 0;
    if (_gen != gen) {
      _ran.clear();
      _gen = gen;
    }
  }

  /// Whether [p] is left out of this run; a pass that runs is noted.
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
