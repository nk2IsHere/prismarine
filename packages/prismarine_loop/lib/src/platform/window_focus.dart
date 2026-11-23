import 'dart:ui' show AppLifecycleState;

/// Tracks the input focus of the window of the app, which an input gate and
/// pointer warps need.
///
/// The lifecycle of the app alone is not the focus of the window. On macOS a
/// panel of another process, such as Spotlight or the overlay of a
/// screenshot, takes the key window while the app stays active and
/// "resumed". The window is focused while the app is resumed and its window
/// is the key window. The runner reports the key window on its key-window
/// channel. The engine on Windows sends view focus events instead. A
/// platform that reports neither keeps the key window true.
class WindowFocus {
  bool _resumed = true;
  bool _key = true;

  bool get focused => _resumed && _key;

  /// Takes the new lifecycle [state] of the app. Null is not known yet and
  /// counts as resumed. Returns true when [focused] changed.
  bool lifecycle(AppLifecycleState? state) => _set(
    () => _resumed = state == null || state == AppLifecycleState.resumed,
  );

  /// Takes [key], true when the window became the key window and false when
  /// it stopped being it. Returns true when [focused] changed.
  bool keyWindow(bool key) => _set(() => _key = key);

  bool _set(void Function() change) {
    final was = focused;
    change();
    return focused != was;
  }
}
