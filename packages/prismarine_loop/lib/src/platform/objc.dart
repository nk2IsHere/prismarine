// The Objective-C runtime and a few CoreFoundation and IOSurface calls,
// through plain dart:ffi (macOS): the platform glue the window-surface reader
// and the Metal frame limiter need. Call only on the main thread (the UI
// isolate with Flutter's merged platform/UI threads) where AppKit is
// involved.
import 'dart:ffi';

typedef ObjcId = Pointer<Void>;

final objcLib = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
final cfLib = DynamicLibrary.open(
  '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
);
final ioSurfaceLib = DynamicLibrary.open(
  '/System/Library/Frameworks/IOSurface.framework/IOSurface',
);

final objcClass = objcLib
    .lookupFunction<
      ObjcId Function(Pointer<Uint8>),
      ObjcId Function(Pointer<Uint8>)
    >('objc_getClass');
final _selRegister = objcLib
    .lookupFunction<
      ObjcId Function(Pointer<Uint8>),
      ObjcId Function(Pointer<Uint8>)
    >('sel_registerName');
final msgSend = objcLib
    .lookupFunction<
      ObjcId Function(ObjcId, ObjcId),
      ObjcId Function(ObjcId, ObjcId)
    >('objc_msgSend');
final msgSendIndex = objcLib
    .lookupFunction<
      ObjcId Function(ObjcId, ObjcId, Uint64),
      ObjcId Function(ObjcId, ObjcId, int)
    >('objc_msgSend');
final msgSendCount = objcLib
    .lookupFunction<
      Uint64 Function(ObjcId, ObjcId),
      int Function(ObjcId, ObjcId)
    >('objc_msgSend');
final msgSendBool = objcLib
    .lookupFunction<
      Uint8 Function(ObjcId, ObjcId),
      int Function(ObjcId, ObjcId)
    >('objc_msgSend');
final cfGetTypeId = cfLib
    .lookupFunction<UintPtr Function(ObjcId), int Function(ObjcId)>(
      'CFGetTypeID',
    );
final cfRetain = cfLib
    .lookupFunction<ObjcId Function(ObjcId), ObjcId Function(ObjcId)>(
      'CFRetain',
    );
final ioSurfaceTypeId = ioSurfaceLib
    .lookupFunction<UintPtr Function(), int Function()>('IOSurfaceGetTypeID');
final ioSurfaceUseInc = ioSurfaceLib
    .lookupFunction<Void Function(ObjcId), void Function(ObjcId)>(
      'IOSurfaceIncrementUseCount',
    );

/// A C string that lives for the process (selectors and class names).
Pointer<Uint8> cString(String s) {
  final units = s.codeUnits;
  final p = _malloc(units.length + 1).cast<Uint8>();
  for (var i = 0; i < units.length; i++) {
    p[i] = units[i];
  }
  p[units.length] = 0;
  return p.cast();
}

final _mallocFn = DynamicLibrary.process()
    .lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
Pointer<Void> _malloc(int n) => _mallocFn(n);

final _sels = <String, ObjcId>{};
ObjcId sel(String name) => _sels[name] ??= _selRegister(cString(name));

final cfRelease = cfLib
    .lookupFunction<Void Function(ObjcId), void Function(ObjcId)>('CFRelease');
