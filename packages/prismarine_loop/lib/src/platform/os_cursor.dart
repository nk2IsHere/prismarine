/// Hides the OS pointer over the game area.
///
/// The game draws its own cursor and the game area asks for no OS cursor
/// with `SystemMouseCursors.none`. On macOS that only swaps in a blank cursor
/// image. The system still owns a cursor there, and "shake to locate" draws
/// it enlarged when the mouse is flung. While the pointer is over the game
/// area the runner therefore also hides the cursor itself with NSCursor
/// hide and unhide through its `setHidden` call. The cursor shows again when
/// the pointer leaves for a debug panel or the edge of the window, or when a
/// review tool takes the area.
///
/// [OsCursorHider] sends only changes and keeps the hide and unhide calls of
/// the runner paired. [dispose] gives the cursor back.
class OsCursorHider {
  OsCursorHider(this._send);

  /// Asks the runner to hide (true) or show (false) the OS cursor.
  final void Function(bool hidden) _send;

  bool _over = false;
  bool _reviewing = false;
  bool _sent = false;

  /// The state last sent to the runner.
  bool get hidden => _sent;

  /// Sets if the pointer is over the game area, from the enter and exit of
  /// its MouseRegion.
  set over(bool v) {
    _over = v;
    _apply();
  }

  /// Sets if a review tool is open over the game area.
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
