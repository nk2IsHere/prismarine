// Mouse-look without pointer warps. While the game hides its cursor and
// re-centres it every frame, the runner holds the OS pointer still and sums
// the movement of the mouse. The cursor of the game is the position that the
// game last set plus that movement in whole device pixels. A travel of the
// width of the screen still crosses the screen.
//
// The file has no Flutter types. Its decisions and arithmetic are tested with
// a fake host.

/// The render area in view points, the screen of the game in the window.
typedef LookArea = ({double left, double top, double width, double height});

/// The side of the runner, such as the mouse-look class of the macOS runner.
abstract interface class MouseLookHost {
  /// The movement of the mouse summed since launch in view points, y down.
  /// Readers take differences of it.
  double get sumX;
  double get sumY;

  /// Holds the pointer at ([x], [y]) in the view. Returns false when refused,
  /// such as in an unattended run or when the window is not the key window.
  bool hold(double x, double y);

  /// Lets the pointer go at ([x], [y]) in the view.
  void letGo(double x, double y);
}

/// Returns true when mouse-look holds the pointer after a frame. The game
/// hid its cursor and re-centred it that frame, the window has focus and
/// neither a debug panel nor a review tool has the pointer.
bool holdsPointer({
  required bool hidden,
  required bool recentred,
  required bool focused,
  required bool panelOpen,
  required bool reviewing,
}) => hidden && recentred && focused && !panelOpen && !reviewing;

/// The cursor of the game from the summed movement of the mouse.
///
/// The anchor is the position that the game last set. The travel since then
/// is kept in whole device pixels with the remainder carried, as
/// GetCursorPos of Windows counts whole pixels of a pointer that moves in
/// finer steps. The read of a frame takes the travel so far ([sample]). The
/// re-centre of the game after it ([set]) moves the anchor and keeps the
/// travel made since the read. No travel counts twice or is lost.
class MouseLookCursor {
  double _sumX = 0, _sumY = 0;
  double _carryX = 0, _carryY = 0;
  double _anchorX = 0.5, _anchorY = 0.5;
  int _travelX = 0, _travelY = 0;
  int _readX = 0, _readY = 0;
  double _width = 1, _height = 1;
  bool _changed = false;

  /// The sums of the host as last taken.
  double get sumX => _sumX;
  double get sumY => _sumY;

  /// The cursor of the game, normalised over the render area.
  double get x => (_anchorX + _travelX / _width).clamp(0.0, 1.0);
  double get y => (_anchorY + _travelY / _height).clamp(0.0, 1.0);

  /// Starts at the cursor ([x], [y]) of the game with the sums [sumX] and
  /// [sumY] of the host now.
  void begin(double sumX, double sumY, double x, double y) {
    _sumX = sumX;
    _sumY = sumY;
    _carryX = _carryY = 0;
    _anchorX = x;
    _anchorY = y;
    _travelX = _travelY = _readX = _readY = 0;
    _changed = false;
  }

  /// Takes the sums [sumX] and [sumY] of the host, the movement since the
  /// last take, at [pixelRatio] device pixels per point over [area]. [event]
  /// is true for a pointer event, which posts the cursor now. The read of the
  /// frame then posts it again.
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
    // At the edge of the area the travel stops, as the pointer stops at the
    // edge of the screen. No fraction is kept past it.
    if (tx != _travelX + wx.toInt()) _carryX = 0;
    if (ty != _travelY + wy.toInt()) _carryY = 0;
    if (tx != _travelX || ty != _travelY || event) _changed = true;
    _travelX = tx;
    _travelY = ty;
  }

  /// Returns [travel] kept within the area. The cursor itself is clamped and
  /// the bounds round outwards, which keeps the edge reachable.
  static int _edge(int travel, double anchor, double size) {
    final lo = (-anchor * size).floor(), hi = ((1 - anchor) * size).ceil();
    return travel < lo ? lo : (travel > hi ? hi : travel);
  }

  /// Reads the cursor for the input of a frame. Returns true when it changed
  /// or an event posted it since the last read.
  bool sample() {
    _readX = _travelX;
    _readY = _travelY;
    final c = _changed;
    _changed = false;
    return c;
  }

  /// Sets the cursor to ([x], [y]) after the game read it. The travel made
  /// since the read counts from there.
  void set(double x, double y) {
    _anchorX = x;
    _anchorY = y;
    _travelX -= _readX;
    _travelY -= _readY;
    _readX = _readY = 0;
  }
}

/// The hold and the cursor that it drives. Without a host, such as on
/// another platform or with an older runner, it does not hold.
class MouseLook {
  MouseLook(this._host);

  final MouseLookHost? _host;
  final cursor = MouseLookCursor();
  bool _held = false;

  /// The place of the held pointer, in view points.
  double holdX = 0, holdY = 0;

  /// True while the pointer is held and the cursor of the game follows the
  /// sums of the mouse.
  bool get held => _held;

  /// Holds the pointer at the view point ([viewX], [viewY]) of the cursor
  /// ([x], [y]) of the game. Returns false without a host or when the host
  /// refused.
  bool hold(double viewX, double viewY, double x, double y) {
    final h = _host;
    if (_held) return true;
    if (h == null || !h.hold(viewX, viewY)) return false;
    // The sums count from after the warp of the hold. The movement before it
    // belongs to the pointer.
    cursor.begin(h.sumX, h.sumY, x, y);
    holdX = viewX;
    holdY = viewY;
    _held = true;
    return true;
  }

  /// Lets the pointer go at the view point ([viewX], [viewY]) of the cursor
  /// of the game. Returns true when it was held.
  bool letGo(double viewX, double viewY) {
    if (!_held) return false;
    _held = false;
    _host?.letGo(viewX, viewY);
    return true;
  }

  /// Takes the sums of the host into the cursor while the pointer is held,
  /// over [area] at [pixelRatio]. [event] is true for a pointer event.
  void read(LookArea area, double pixelRatio, {bool event = false}) {
    final h = _host;
    if (!_held || h == null) return;
    cursor.take(h.sumX, h.sumY, area, pixelRatio, event: event);
  }
}
