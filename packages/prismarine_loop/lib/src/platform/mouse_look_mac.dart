// The macOS runner's McsmMouseLook (MainFlutterWindow.swift) through the
// Objective-C runtime: synchronous calls on the UI isolate, which runs on
// the main thread with Flutter's merged platform and UI threads, so a read
// costs two message sends and waits for no answer.
import 'dart:ffi';

import 'mouse_look.dart';
import 'objc.dart';

final _msgSendDouble = objcLib
    .lookupFunction<
      Double Function(ObjcId, ObjcId),
      double Function(ObjcId, ObjcId)
    >('objc_msgSend');
final _msgSendHold = objcLib
    .lookupFunction<
      Uint8 Function(ObjcId, ObjcId, Double, Double),
      int Function(ObjcId, ObjcId, double, double)
    >('objc_msgSend');
final _msgSendLetGo = objcLib
    .lookupFunction<
      Void Function(ObjcId, ObjcId, Double, Double),
      void Function(ObjcId, ObjcId, double, double)
    >('objc_msgSend');

class MacMouseLookHost implements MouseLookHost {
  MacMouseLookHost._(this._class);

  /// The runner's class [className], or null (a runner built before it).
  static MacMouseLookHost? find(String className) {
    final c = objcClass(cString(className));
    return c == nullptr ? null : MacMouseLookHost._(c);
  }

  final ObjcId _class;
  final _totalX = sel('totalX');
  final _totalY = sel('totalY');
  final _hold = sel('holdAtX:y:');
  final _letGo = sel('letGoAtX:y:');

  @override
  double get sumX => _msgSendDouble(_class, _totalX);

  @override
  double get sumY => _msgSendDouble(_class, _totalY);

  @override
  bool hold(double x, double y) => _msgSendHold(_class, _hold, x, y) & 1 != 0;

  @override
  void letGo(double x, double y) => _msgSendLetGo(_class, _letGo, x, y);
}
