/// The OS pointer over the game area.
///
/// The game draws its own cursor, so the game area asks for no OS cursor
/// (`SystemMouseCursors.none`). On macOS that only swaps in a blank cursor
/// image: the system still owns a cursor there, and "shake to locate" draws
/// it enlarged when the mouse is flung. So while the pointer is over
/// the game area the runner also hides the cursor itself (NSCursor
/// hide/unhide through its `setHidden` call), and shows it again when the
/// pointer leaves (a debug panel, the window's edge) or a review tool takes
/// the area (its tools want the OS pointer).
///
/// [OsCursorHider] decides when to ask: it sends only changes, so the
/// runner's hide and unhide calls stay paired, and [dispose] gives the
/// cursor back.
class OsCursorHider {
  OsCursorHider(this._send);

  /// Asks the runner to hide (true) or show (false) the OS cursor.
  final void Function(bool hidden) _send;

  bool _over = false;
  bool _reviewing = false;
  bool _sent = false;

  /// What was last asked of the runner.
  bool get hidden => _sent;

  /// The pointer is over the game area (its MouseRegion's enter/exit).
  set over(bool v) {
    _over = v;
    _apply();
  }

  /// A review tool is open over the game area.
  set reviewing(bool v) {
    _reviewing = v;
    _apply();
  }

  void dispose() {
    _over = false;
    _apply();
  }

  void _apply() {
    final want = _over && !_reviewing;
    if (want == _sent) return;
    _sent = want;
    _send(want);
  }
}
