import 'dart:ui' show AppLifecycleState;

/// Whether the app's window has the input focus, which an input gate and
/// pointer warps need.
///
/// The app's lifecycle alone is not the window's focus: on macOS a panel of
/// another process (Spotlight and the like, a screenshot's overlay) takes
/// the key window while the app stays active and "resumed", and an app
/// would go on warping the pointer under it. So the window is focused while
/// the app is resumed and its window is the key window, as the runner
/// reports it on its key-window channel (Windows' engine sends view focus
/// events instead). A platform that reports neither keeps the key window
/// true.
class WindowFocus {
  bool _resumed = true;
  bool _key = true;

  bool get focused => _resumed && _key;

  /// The app's lifecycle changed (null: not known yet, taken as resumed).
  /// True when [focused] changed.
  bool lifecycle(AppLifecycleState? state) => _set(
    () => _resumed = state == null || state == AppLifecycleState.resumed,
  );

  /// The window became (true) or stopped being (false) the key window.
  /// True when [focused] changed.
  bool keyWindow(bool key) => _set(() => _key = key);

  bool _set(void Function() change) {
    final was = focused;
    change();
    return focused != was;
  }
}
