// The macOS embedder of Flutter presents each composited frame as an
// IOSurface set as the contents of a CALayer (FlutterSurfaceManager). Each UI
// frame this file takes the surface that the window shows now on the AppKit
// main thread. It keeps the surface from reuse with IOSurfaceIncrementUseCount
// and passes it to a worker isolate. The worker locks it, which waits for the
// GPU to finish writing it, reads a copy and lets it go.
//
// It calls the Objective-C runtime and the IOSurface C API through dart:ffi.
// It works only with merged platform and UI threads, the default of Flutter.
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:prismarine_loop/objc.dart';

import 'window_surface.dart';
import 'window_surface_pixels.dart';

/// The surfaces of the window on macOS.
class MacSurfaceSource implements SurfaceSource {
  MacSurfaceSource._();

  /// Returns the source, or null when the UI isolate is not on the main
  /// thread.
  static MacSurfaceSource? open() {
    final isMain = msgSendBool(
      objcClass(cString('NSThread')),
      sel('isMainThread'),
    );
    return isMain == 0 ? null : MacSurfaceSource._();
  }

  @override
  void Function(WorkerArgs) get worker => _readerMain;

  @override
  Object? get workerArg => null;

  @override
  Object? take() {
    final surface = _shownSurface();
    if (surface == null) return null;
    cfRetain(surface);
    ioSurfaceUseInc(surface);
    return surface.address;
  }

  // Returns the layer trees of the windows, for a log line when no surface is
  // found.
  @override
  String describe() {
    final out = StringBuffer();
    final app = msgSend(
      objcClass(cString('NSApplication')),
      sel('sharedApplication'),
    );
    final windows = msgSend(app, sel('windows'));
    final n = msgSendCount(windows, sel('count'));
    out.write('$n windows');
    String cls(ObjcId o) {
      final name = msgSend(msgSend(o, sel('className')), sel('UTF8String'));
      if (name == nullptr) return '?';
      final b = name.cast<Uint8>();
      var k = 0;
      while (b[k] != 0 && k < 64) {
        k++;
      }
      return String.fromCharCodes(b.asTypedList(k));
    }

    void walk(ObjcId layer, int depth) {
      if (layer == nullptr || depth > 4) return;
      final c = msgSend(layer, sel('contents'));
      out.write(
        ' ${'>' * depth}${cls(layer)}'
        '${c == nullptr ? '' : '[${cls(c)}]'}',
      );
      final subs = msgSend(layer, sel('sublayers'));
      if (subs == nullptr) return;
      final k = msgSendCount(subs, sel('count'));
      for (var i = 0; i < k; i++) {
        walk(msgSendIndex(subs, sel('objectAtIndex:'), i), depth + 1);
      }
    }

    for (var i = 0; i < n; i++) {
      final w = msgSendIndex(windows, sel('objectAtIndex:'), i);
      final view = msgSend(w, sel('contentView'));
      out.write(
        '; window $i ${cls(w)} view ${view == nullptr ? '-' : cls(view)}:',
      );
      if (view != nullptr) walk(msgSend(view, sel('layer')), 0);
    }
    return out.toString();
  }

  static ObjcId? _shownSurface() {
    final app = msgSend(
      objcClass(cString('NSApplication')),
      sel('sharedApplication'),
    );
    final windows = msgSend(app, sel('windows'));
    final n = msgSendCount(windows, sel('count'));
    for (var i = 0; i < n; i++) {
      final w = msgSendIndex(windows, sel('objectAtIndex:'), i);
      final view = msgSend(w, sel('contentView'));
      if (view == nullptr) continue;
      final layer = msgSend(view, sel('layer'));
      final found = _find(layer, 0);
      if (found != null) return found;
    }
    return null;
  }

  // Returns the first layer, depth-first and at most 4 deep, whose contents
  // are an IOSurface. It is the lowest content layer of the embedder.
  static ObjcId? _find(ObjcId layer, int depth) {
    if (layer == nullptr || depth > 4) return null;
    final contents = msgSend(layer, sel('contents'));
    if (contents != nullptr && cfGetTypeId(contents) == ioSurfaceTypeId()) {
      return contents;
    }
    final subs = msgSend(layer, sel('sublayers'));
    if (subs == nullptr) return null;
    final n = msgSendCount(subs, sel('count'));
    for (var i = 0; i < n; i++) {
      final f = _find(msgSendIndex(subs, sel('objectAtIndex:'), i), depth + 1);
      if (f != null) return f;
    }
    return null;
  }
}

void _readerMain(WorkerArgs args) {
  final (ready, out, width, _) = args;
  final ios = DynamicLibrary.open(
    '/System/Library/Frameworks/IOSurface.framework/IOSurface',
  );
  final cf = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );
  final lock = ios
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Uint32>)
      >('IOSurfaceLock');
  final unlock = ios
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Uint32>)
      >('IOSurfaceUnlock');
  final base = ios
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('IOSurfaceGetBaseAddress');
  int Function(Pointer<Void>) size(String name) =>
      ios.lookupFunction<
        UintPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >(name);
  final rowBytes = size('IOSurfaceGetBytesPerRow');
  final sw = size('IOSurfaceGetWidth');
  final sh = size('IOSurfaceGetHeight');
  final format = ios
      .lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('IOSurfaceGetPixelFormat');
  final useDec = ios
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('IOSurfaceDecrementUseCount');
  final release = cf
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
  const readOnly = 1; // kIOSurfaceLockReadOnly
  const bgra = 0x42475241; // 'BGRA'
  // 'w40a' is MTLPixelFormatBGRA10_XR of a wide-gamut window.
  const bgra10xr = 0x77343061;
  final frames = FrameSender(out, width);
  final port = ReceivePort();
  ready.send(port.sendPort);
  port.listen((m) {
    if (m == null) {
      port.close();
      return;
    }
    final s = Pointer<Void>.fromAddress(m as int);
    try {
      final f = format(s);
      if (f != bgra && f != bgra10xr) {
        frames.note('pixel format 0x${f.toRadixString(16)}');
        return;
      }
      final rc = lock(s, readOnly, nullptr);
      if (rc != 0) {
        frames.note('lock failed $rc');
        return;
      }
      try {
        final w = sw(s), h = sh(s), stride = rowBytes(s);
        if (w <= 0 || h <= 0) return;
        final oh = scaledHeight(w, h, width);
        final rgba = Uint8List(width * oh * 4);
        final sum = f == bgra10xr
            ? scaleBgra10Xr(
                base(s).cast<Uint16>().asTypedList(stride * h >> 1),
                w,
                h,
                stride,
                rgba,
                width,
                oh,
              )
            : scaleBgra8(
                base(s).asTypedList(stride * h),
                w,
                h,
                stride,
                rgba,
                width,
                oh,
              );
        frames.send(rgba, oh, sum);
      } finally {
        unlock(s, readOnly, nullptr);
      }
    } finally {
      useDec(s);
      release(s);
    }
  });
}
