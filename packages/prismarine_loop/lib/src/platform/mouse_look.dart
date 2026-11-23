// Mouse-look without pointer warps. While the game hides its cursor and
// re-centres it every frame (S2's ReticleController; the exe's SetCursorPos
// and GetCursorPos [LOCAL ReticleController.lua]), the runner holds the OS
// pointer still and sums the mouse's own movement; the game's cursor is the
// position the game last set plus that movement in whole device pixels, so
// a screen's width of travel still crosses the screen (quirk
// Q-input-s2-reticle-pointer-speed). Warping the pointer back every frame
// fought the hand: the pointer stood still for frames mid-motion and the
// events around each warp disagreed with its place.
//
// Pure Dart (no Flutter types): the decisions and the arithmetic are unit
// tested with a fake host.

/// The render area in view points (the game's screen in the window).
typedef LookArea = ({double left, double top, double width, double height});

/// The runner's side (macOS MainFlutterWindow.swift, McsmMouseLook).
abstract interface class MouseLookHost {
  /// The mouse's movement summed since launch, in view points, y down;
  /// only grows, readers take differences.
  double get sumX;
  double get sumY;

  /// Holds the pointer at ([x], [y]) in the view; false when refused
  /// (an unattended run, the window not key).
  bool hold(double x, double y);

  /// Lets the pointer go at ([x], [y]) in the view.
  void letGo(double x, double y);
}

/// Whether mouse-look holds the pointer after a frame: the game hid its
/// cursor and re-centred it that frame, the window has focus, and neither
/// the F1 panel nor the F7 review has the pointer.
bool holdsPointer({
  required bool hidden,
  required bool recentred,
  required bool focused,
  required bool panelOpen,
  required bool reviewing,
}) => hidden && recentred && focused && !panelOpen && !reviewing;

/// The game's cursor from the mouse's summed movement.
///
/// The anchor is the position the game last set; the travel since is kept
/// in whole device pixels with the remainder carried, as the exe's
/// GetCursorPos counts whole pixels of a pointer moving in finer steps.
/// The frame's read takes the travel so far ([sample]); the game's
/// re-centre after it ([set]) moves the anchor and keeps the travel made
/// since the read, so nothing counts twice and nothing is lost. Fields, not
/// records: it runs for every pointer event and every frame.
class MouseLookCursor {
  double _sumX = 0, _sumY = 0;
  double _carryX = 0, _carryY = 0;
  double _anchorX = 0.5, _anchorY = 0.5;
  int _travelX = 0, _travelY = 0;
  int _readX = 0, _readY = 0;
  double _width = 1, _height = 1;
  bool _changed = false;

  /// The host's sums as last taken (the run trace's record of the
  /// mouse's movement).
  double get sumX => _sumX;
  double get sumY => _sumY;

  /// The game's cursor, normalised over the render area.
  double get x => (_anchorX + _travelX / _width).clamp(0.0, 1.0);
  double get y => (_anchorY + _travelY / _height).clamp(0.0, 1.0);

  /// Starts at the game's cursor ([x], [y]) with the host's sums now.
  void begin(double sumX, double sumY, double x, double y) {
    _sumX = sumX;
    _sumY = sumY;
    _carryX = _carryY = 0;
    _anchorX = x;
    _anchorY = y;
    _travelX = _travelY = _readX = _readY = 0;
    _changed = false;
  }

  /// Takes the host's sums: the movement since the last take, at
  /// [pixelRatio] device pixels per point, over [area]. [event]: a pointer
  /// event posts the cursor now, so the frame's read posts it again.
  void take(
    double sumX,
    double sumY,
    LookArea area,
    double pixelRatio, {
    bool event = false,
  }) {
    _width = area.width * pixelRatio;
    _height = area.height * pixelRatio;
    final dx = (sumX - _sumX) * pixelRatio + _carryX;
    final dy = (sumY - _sumY) * pixelRatio + _carryY;
    _sumX = sumX;
    _sumY = sumY;
    final wx = dx.floorToDouble(), wy = dy.floorToDouble();
    _carryX = dx - wx;
    _carryY = dy - wy;
    final tx = _edge(_travelX + wx.toInt(), _anchorX, _width);
    final ty = _edge(_travelY + wy.toInt(), _anchorY, _height);
    // At the area's edge the travel stops, as the pointer stops at the
    // screen's, and no fraction is kept past it.
    if (tx != _travelX + wx.toInt()) _carryX = 0;
    if (ty != _travelY + wy.toInt()) _carryY = 0;
    if (tx != _travelX || ty != _travelY || event) _changed = true;
    _travelX = tx;
    _travelY = ty;
  }

  /// The travel kept within the area (the cursor itself is clamped, so the
  /// bounds round outwards: the edge is always reachable).
  static int _edge(int travel, double anchor, double size) {
    final lo = (-anchor * size).floor(), hi = ((1 - anchor) * size).ceil();
    return travel < lo ? lo : (travel > hi ? hi : travel);
  }

  /// The game reads the cursor (each frame's input is sent): true when it
  /// changed, or was posted by an event, since the last read.
  bool sample() {
    _readX = _travelX;
    _readY = _travelY;
    final c = _changed;
    _changed = false;
    return c;
  }

  /// The game set its cursor to ([x], [y]) after reading it: the travel
  /// made since the read counts from there.
  void set(double x, double y) {
    _anchorX = x;
    _anchorY = y;
    _travelX -= _readX;
    _travelY -= _readY;
    _readX = _readY = 0;
  }
}

/// The hold and the cursor it drives; without a host (other platforms, an
/// older runner) it never holds.
class MouseLook {
  MouseLook(this._host);

  final MouseLookHost? _host;
  final cursor = MouseLookCursor();
  bool _held = false;

  /// Where the hold put the pointer, in view points.
  double holdX = 0, holdY = 0;

  /// The pointer is held and the game's cursor follows the mouse's sums.
  bool get held => _held;

  /// Holds the pointer at the view point ([viewX], [viewY]) of the game's
  /// cursor ([x], [y]). False when there is no host or it refused.
  bool hold(double viewX, double viewY, double x, double y) {
    final h = _host;
    if (_held) return true;
    if (h == null || !h.hold(viewX, viewY)) return false;
    // The sums after the hold's warp: movement before it was the pointer's.
    cursor.begin(h.sumX, h.sumY, x, y);
    holdX = viewX;
    holdY = viewY;
    _held = true;
    return true;
  }

  /// Lets the pointer go at the view point of the game's cursor; true when
  /// it was held.
  bool letGo(double viewX, double viewY) {
    if (!_held) return false;
    _held = false;
    _host?.letGo(viewX, viewY);
    return true;
  }

  /// Takes the host's sums into the cursor (held only).
  void read(LookArea area, double pixelRatio, {bool event = false}) {
    final h = _host;
    if (!_held || h == null) return;
    cursor.take(h.sumX, h.sumY, area, pixelRatio, event: event);
  }
}
