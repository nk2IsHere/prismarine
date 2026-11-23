import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

void main() {
  test('a panel of another process takes the key window while the app '
      'stays resumed: the window is unfocused until it is key again', () {
    final f = WindowFocus()..lifecycle(AppLifecycleState.resumed);
    expect(f.focused, isTrue);
    expect(f.keyWindow(false), isTrue);
    expect(f.focused, isFalse);
    expect(f.lifecycle(AppLifecycleState.resumed), isFalse);
    expect(f.focused, isFalse);
    expect(f.keyWindow(true), isTrue);
    expect(f.focused, isTrue);
  });

  test('another app in front: unfocused whatever the key window says', () {
    final f = WindowFocus();
    expect(f.lifecycle(AppLifecycleState.inactive), isTrue);
    expect(f.keyWindow(true), isFalse);
    expect(f.focused, isFalse);
    expect(f.lifecycle(AppLifecycleState.resumed), isTrue);
    expect(f.focused, isTrue);
  });

  test('a platform that reports no key window follows the lifecycle', () {
    final f = WindowFocus()..lifecycle(null);
    expect(f.focused, isTrue);
  });
}
