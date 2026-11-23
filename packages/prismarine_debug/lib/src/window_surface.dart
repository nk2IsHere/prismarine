// What the macOS window really shows: Flutter's macOS
// embedder presents each composited frame as an IOSurface set as a CALayer's
// contents (FlutterSurfaceManager). Each UI frame this takes the surface the
// window shows now (main thread: AppKit), keeps it from being reused
// (IOSurfaceIncrementUseCount) and hands it to a worker isolate, which locks
// it (that waits for the GPU to finish writing it, off the UI thread), reads
// a 640-wide copy and lets it go. The glitch catcher checks those frames as
// it checks the history ring's: a glitch in Flutter's own compositing, after
// our textures, shows only here.
//
// Plain dart:ffi on the Objective-C runtime and the IOSurface C API; macOS
// only, and only with merged platform/UI threads (Flutter's default).
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:prismarine_loop/objc.dart';

/// Takes the window's shown surface each UI frame and reads it on a worker.
class WindowSurfaceReader {
  WindowSurfaceReader._(this._send);

  /// A reader that hands each new frame to [onFrame] (RGBA, [width] wide,
  /// on the UI isolate), or null where it can't work (not macOS, or the UI
  /// isolate isn't on the main thread).
  static Future<WindowSurfaceReader?> start(
    void Function(Uint8List rgba, int width, int height) onFrame, {
    int width = 640,
  }) async {
    if (!Platform.isMacOS) return null;
    final isMain = msgSendBool(
      objcClass(cString('NSThread')),
      sel('isMainThread'),
    );
    if (isMain == 0) return null;
    final port = ReceivePort();
    final ready = ReceivePort();
    await Isolate.spawn(_readerMain, (ready.sendPort, port.sendPort, width));
    final send = await ready.first as SendPort;
    late final WindowSurfaceReader reader;
    port.listen((m) {
      if (m is String) {
        reader.note = '${reader.note ?? ''} $m';
        return;
      }
      final l = m as List;
      onFrame(
        (l[0] as TransferableTypedData).materialize().asUint8List(),
        l[1] as int,
        l[2] as int,
      );
    });
    return reader = WindowSurfaceReader._(send);
  }

  final SendPort _send;
  int taken = 0, missed = 0;
  String? note;

  /// Call once per UI frame: the surface the window shows now goes to the
  /// worker (it reads it once the GPU is done with it).
  void take() {
    final surface = _shownSurface();
    if (surface == null) {
      if (missed++ == 0) note = _describe();
      return;
    }
    cfRetain(surface);
    ioSurfaceUseInc(surface);
    taken++;
    _send.send(surface.address);
  }

  void close() => _send.send(null);

  // The windows' layer trees, for a log line when no surface is found.
  static String _describe() {
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

  // The first layer (depth-first, at most 4 deep) whose contents are an
  // IOSurface: the embedder's lowest content layer.
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

void _readerMain((SendPort, SendPort, int) args) {
  final (ready, out, width) = args;
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
  // 'w40a' (MTLPixelFormatBGRA10_XR, the wide-gamut window): B, G, R, A as
  // 16 bits each, the 10-bit value in the top bits, extended range
  // (384 = 0.0, 894 = 1.0).
  const bgra10xr = 0x77343061;
  final xr = Uint8List(1024);
  for (var v = 0; v < 1024; v++) {
    xr[v] = (((v - 384) / 510).clamp(0.0, 1.0) * 255).round();
  }
  var lastSum = -1, notes = 0;
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
        if (notes++ < 2) out.send('pixel format 0x${f.toRadixString(16)}');
        return;
      }
      final rc = lock(s, readOnly, nullptr);
      if (rc != 0) {
        if (notes++ < 2) out.send('lock failed $rc');
        return;
      }
      try {
        final w = sw(s), h = sh(s), stride = rowBytes(s);
        if (w <= 0 || h <= 0) return;
        final oh = (h * width / w).round();
        final rgba = Uint8List(width * oh * 4);
        final src = base(s);
        final wide = f == bgra10xr;
        final src16 = src.cast<Uint16>();
        var sum = 0;
        for (var y = 0; y < oh; y++) {
          final row = (y * h ~/ oh) * stride;
          for (var x = 0; x < width; x++) {
            final o = (y * width + x) * 4;
            if (wide) {
              final p = (row + (x * w ~/ width) * 8) >> 1;
              rgba[o] = xr[src16[p + 2] >> 6];
              rgba[o + 1] = xr[src16[p + 1] >> 6];
              rgba[o + 2] = xr[src16[p] >> 6];
            } else {
              final p = row + (x * w ~/ width) * 4;
              rgba[o] = src[p + 2];
              rgba[o + 1] = src[p + 1];
              rgba[o + 2] = src[p];
            }
            rgba[o + 3] = 255;
            sum = (sum * 31 + rgba[o] + rgba[o + 1] + rgba[o + 2]) & 0x3fffffff;
          }
        }
        // The same picture again (no new present since the last take).
        if (sum == lastSum) return;
        lastSum = sum;
        out.send([
          TransferableTypedData.fromList([rgba]),
          width,
          oh,
        ]);
      } finally {
        unlock(s, readOnly, nullptr);
      }
    } finally {
      useDec(s);
      release(s);
    }
  });
}
