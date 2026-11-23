/// Frame pacing: the game steps on every [divisor]-th display frame, so a
/// scene the machine can't draw at the display's rate plays at an even
/// half, third or quarter of it rather than at an uneven rate in between
/// (a display without variable refresh shows a picture for whole frames
/// only: 70 pictures a second on 120 Hz is a mix of one- and two-frame
/// pictures, the game's steps as uneven as their pictures).
///
/// It decides once a [window] from what happened in it: down a rate when
/// steps came late or too few of them got a picture, up a rate when every
/// stage's time fits the faster one. A rate that didn't hold is tried again
/// after a longer wait each time, so a scene on the edge settles on the
/// slower rate. A replay of recorded frames steps one recorded frame each
/// tick and leaves pacing off.
class FramePace {
  FramePace({this.enabled = true, int? fixed, this.maxDivisor = 4})
    : _fixed = fixed,
      divisor = fixed ?? 1;

  /// Off: every display frame steps.
  final bool enabled;

  /// `--pace=<n>`: this divisor, never changed.
  final int? _fixed;
  final int maxDivisor;

  /// The game steps every this many display frames.
  int divisor;

  /// The display's frame interval in microseconds.
  int intervalUs = 16667;

  /// The display's frame interval in seconds, unrounded (1 / refresh rate):
  /// a step's game time ([stepSeconds]).
  double intervalSeconds = 1 / 60;

  /// The last [begin]'s step in seconds: its display frames times
  /// [intervalSeconds]. Whole microseconds fall short of a 60 Hz frame
  /// (16,666 µs at 120 Hz, two frames), so a clock that sums them runs
  /// 0.67 µs a step behind a fixed 1/60 s step and a key on a frame's time
  /// comes a frame late.
  double stepSeconds = 0;

  /// A decision's span.
  static const window = 1000000;

  /// A gap this long is a load or a pause, not the rate's doing.
  static const _hitchUs = 100000;

  /// Rate changes so far (the run log).
  int downs = 0, ups = 0;

  int _windowStartUs = -1;
  int _steps = 0, _late = 0, _presented = 0, _shownAtStart = 0;
  int _simOver = 0, _uiOver = 0, _buildOver = 0, _gpuOver = 0, _chainOver = 0;
  int _badWindows = 0, _fitWindows = 0;

  /// Fitting windows a step up waits for; doubles when the faster rate
  /// didn't hold.
  int _upHold = _firstHold;
  int _upAtUs = -1;
  static const _firstHold = 2, _maxHold = 32;

  /// A faster rate that held this long is no failed try.
  static const _heldUs = 30000000;

  /// The display frame at [nowUs] (a tick's start): the game time it steps
  /// in microseconds, or -1 when it steps nothing at this pace.
  ///
  /// A tick starts some milliseconds after its display frame does, later
  /// when the UI isolate was busy, so ticks' own distances are uneven where
  /// the pictures' are not. Steps are counted in display frames instead: a
  /// grid of frame starts follows the earliest ticks, a tick belongs to the
  /// frame it started in, and a step is as long as the frames since the
  /// last one. The steps add up to the clock's time.
  int begin(int nowUs) {
    final grid = _gridUs;
    if (grid < 0) {
      _gridUs = nowUs;
      return 0;
    }
    final frames = (nowUs - grid + intervalUs ~/ 10) ~/ intervalUs;
    if (frames < divisor) return -1;
    final stepUs = frames * intervalUs;
    stepSeconds = frames * intervalSeconds;
    if (stepUs < _hitchUs) {
      _steps++;
      if (frames > divisor) _late++;
    }
    // The frame's start: this tick's, when it came earlier than the grid
    // had it; else the grid moves a little toward it, so a display that
    // runs slower than [intervalUs] says does not leave the grid behind.
    final at = grid + stepUs, ahead = nowUs - at;
    _gridUs = ahead < 0 ? nowUs : at + (ahead < _leakUs ? ahead : _leakUs);
    return stepUs;
  }

  int _gridUs = -1;
  static const _leakUs = 20;

  /// A step's end: whether it was [presented] (a held frame shows no new
  /// picture), the pictures [shown] so far, and the step's stage times in
  /// ms (the sim's tick, the UI isolate's own work with the record, the
  /// plan's build, the frame's own time on the GPU). Decides at a window's
  /// end; true when the divisor changed.
  bool end(
    int nowUs, {
    required bool presented,
    required int shown,
    required double simMs,
    required double uiMs,
    required double buildMs,
    required double gpuMs,
  }) {
    if (!enabled || _fixed != null) return false;
    if (_windowStartUs < 0) _open(nowUs, shown);
    if (presented) _presented++;
    // What the next faster rate allows: the stages a tick waits for must
    // fit its interval; the build and the GPU only bound the pictures, and
    // a rate holds while about four in five steps get theirs. A step's
    // plan is built after its sim tick and recorded on the UI isolate
    // while the next tick waits for the sim, so that tick is late unless
    // the three together fit two intervals.
    final faster = (divisor > 1 ? divisor - 1 : 1) * intervalUs / 1000;
    if (simMs > 0.95 * faster) _simOver++;
    if (uiMs > 0.95 * faster) _uiOver++;
    if (buildMs > 1.25 * faster) _buildOver++;
    if (gpuMs > 1.25 * faster) _gpuOver++;
    if (simMs + buildMs + uiMs > 1.8 * faster) _chainOver++;
    if (nowUs - _windowStartUs < window) return false;
    final changed = _decide(nowUs, shown - _shownAtStart);
    _open(nowUs, shown);
    return changed;
  }

  void _open(int nowUs, int shown) {
    _windowStartUs = nowUs;
    _shownAtStart = shown;
    _steps = _late = _presented = 0;
    _simOver = _uiOver = _buildOver = _gpuOver = _chainOver = 0;
  }

  bool _decide(int nowUs, int pictures) {
    // A window of loads, holds or a pause says nothing about the rate.
    if (_steps < 20) return false;
    if (_upAtUs >= 0 && nowUs - _upAtUs > _heldUs) {
      _upAtUs = -1;
      _upHold = _firstHold;
    }
    final judged = _presented >= 20;
    final bad =
        4 * _late > _steps || (judged && 100 * pictures < 72 * _presented);
    final veryBad =
        2 * _late > _steps || (judged && 100 * pictures < 55 * _presented);
    if (bad) {
      _fitWindows = 0;
      _badWindows++;
      if (divisor < maxDivisor && (veryBad || _badWindows >= 2)) {
        divisor++;
        downs++;
        _badWindows = 0;
        if (_upAtUs >= 0) {
          _upAtUs = -1;
          _upHold = _upHold * 2 > _maxHold ? _maxHold : _upHold * 2;
        }
        return true;
      }
      return false;
    }
    _badWindows = 0;
    final most = _steps ~/ 10;
    final fits =
        divisor > 1 &&
        _simOver <= most &&
        _uiOver <= most &&
        _buildOver <= most &&
        _gpuOver <= most &&
        _chainOver <= most;
    if (!fits) {
      _fitWindows = 0;
      return false;
    }
    if (++_fitWindows < _upHold) return false;
    divisor--;
    ups++;
    _fitWindows = 0;
    _upAtUs = nowUs;
    return true;
  }

  /// The run's summary line.
  String get summary => !enabled
      ? 'frame pacing: off'
      : 'frame pacing: every ${divisor == 1 ? '' : '$divisor. '}display '
            'frame at the end, $downs down, $ups up';
}
