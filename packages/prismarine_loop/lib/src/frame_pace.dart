/// Frame pacing. The game steps on every [divisor]-th display frame. A scene
/// that the machine cannot draw at the rate of the display then plays at an
/// even half, third or quarter of it, not at an uneven rate in between. A
/// display without variable refresh shows each picture for whole frames
/// only.
///
/// The pace decides once per [window] from the steps in it. It goes down a
/// rate when steps came late or too few of them got a picture. It goes up a
/// rate when the time of every stage fits the faster rate. A rate that did
/// not hold is tried again after a longer wait each time, and a scene on the
/// edge settles on the slower rate. A replay of recorded frames steps one
/// recorded frame each tick and leaves pacing off.
class FramePace {
  FramePace({this.enabled = true, int? fixed, this.maxDivisor = 4})
    : _fixed = fixed,
      divisor = fixed ?? 1;

  /// False when every display frame steps.
  final bool enabled;

  /// The fixed divisor of `--pace=<n>`, which does not change.
  final int? _fixed;
  final int maxDivisor;

  /// The number of display frames per game step.
  int divisor;

  /// The frame interval of the display in microseconds.
  int intervalUs = 16667;

  /// The frame interval of the display in seconds, 1 / refresh rate without
  /// rounding. [stepSeconds] counts in it.
  double intervalSeconds = 1 / 60;

  /// The step of the last [begin] in seconds, its display frames times
  /// [intervalSeconds]. A clock must sum this value and not whole
  /// microseconds. Two 120 Hz frames are 16,666 µs and fall 0.67 µs short of
  /// a 60 Hz frame, which makes a key on the time of a frame come a frame
  /// late.
  double stepSeconds = 0;

  /// The span of one decision in microseconds.
  static const window = 1000000;

  /// A gap this long is a load or a pause and not an effect of the rate.
  static const _hitchUs = 100000;

  /// The rate changes so far.
  int downs = 0, ups = 0;

  int _windowStartUs = -1;
  int _steps = 0, _late = 0, _presented = 0, _shownAtStart = 0;
  int _simOver = 0, _uiOver = 0, _buildOver = 0, _gpuOver = 0, _chainOver = 0;
  int _badWindows = 0, _fitWindows = 0;

  /// The number of fitting windows before a step up. It doubles when the
  /// faster rate did not hold.
  int _upHold = _firstHold;
  int _upAtUs = -1;
  static const _firstHold = 2, _maxHold = 32;

  /// A faster rate that held this long does not count as a failed try.
  static const _heldUs = 30000000;

  /// Begins the display frame of the tick that starts at [nowUs]. Returns
  /// the game time that it steps in microseconds, or -1 when it steps nothing
  /// at this pace.
  ///
  /// A tick starts some milliseconds after its display frame, and later when
  /// the UI isolate was busy. The distances of ticks are therefore uneven
  /// where those of the pictures are not. Steps are counted in display
  /// frames instead. A grid of frame starts follows the earliest ticks. A
  /// tick belongs to the frame that it started in. A step is as long as the
  /// frames since the last step. The steps add up to the time of the clock.
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
    // The start of the frame is the start of this tick when it came earlier
    // than the grid. Otherwise the grid moves a little toward the tick. A
    // display that runs slower than [intervalUs] then does not leave the grid
    // behind.
    final at = grid + stepUs, ahead = nowUs - at;
    _gridUs = ahead < 0 ? nowUs : at + (ahead < _leakUs ? ahead : _leakUs);
    return stepUs;
  }

  int _gridUs = -1;
  static const _leakUs = 20;

  /// Ends a step. [presented] is false for a held frame, which shows no new
  /// picture. [shown] counts the pictures so far. The stage times of the step
  /// in ms are the tick of the simulation, the work of the UI isolate with
  /// the record, the build of the plan and the time of the frame on the GPU.
  /// Decides at the end of a window and returns true when the divisor
  /// changed.
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
    // The limits of the next faster rate. The stages that a tick waits for
    // must fit its interval. The build and the GPU only bound the pictures.
    // A rate holds while about four in five steps get their picture. The plan
    // of a step is built after its simulation tick and recorded on the UI
    // isolate while the next tick waits for the simulation. That tick is late
    // unless the three stages together fit two intervals.
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
    // A window of loads, holds or a pause does not measure the rate.
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

  /// The summary line of the run.
  String get summary => !enabled
      ? 'frame pacing: off'
      : 'frame pacing: every ${divisor == 1 ? '' : '$divisor. '}display '
            'frame at the end, $downs down, $ups up';
}
