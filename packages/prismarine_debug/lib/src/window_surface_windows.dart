// The Windows embedder of Flutter presents each composited frame into the
// child window of the view, which fills the client area of a toplevel window
// of the process. A worker finds that toplevel and copies its client area
// with PrintWindow and PW_RENDERFULLCONTENT into a DIB section. The copy
// comes from the composition of the desktop window manager. It holds the
// frames of a swap chain and is complete while other windows cover the
// window.
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show calloc, Utf16, StringUtf16Pointer;

import 'window_surface.dart';
import 'window_surface_pixels.dart';

typedef _Ptr = Pointer<Void>;

/// The client area of the toplevel window of the Flutter view on Windows.
class WindowsSurfaceSource implements SurfaceSource {
  WindowsSurfaceSource._();

  /// Returns the source. The worker finds the window at its first read.
  static WindowsSurfaceSource open() => WindowsSurfaceSource._();

  @override
  void Function(WorkerArgs) get worker => _readerMain;

  @override
  Object? get workerArg => null;

  @override
  Object? take() => 0;

  @override
  String describe() => '';
}

/// The size of a `BITMAPINFOHEADER`.
const bitmapInfoBytes = 40;

/// Fills the `BITMAPINFOHEADER` at [info] for a top-down DIB of [width] by
/// [height] with 32 bits per pixel.
void fillBitmapInfo(Pointer<Uint8> info, int width, int height) {
  final b = info.asTypedList(bitmapInfoBytes)..fillRange(0, bitmapInfoBytes, 0);
  ByteData.sublistView(b)
    ..setUint32(0, bitmapInfoBytes, Endian.little) // biSize
    ..setInt32(4, width, Endian.little)
    ..setInt32(8, -height, Endian.little) // a negative height is top-down
    ..setUint16(12, 1, Endian.little) // biPlanes
    ..setUint16(14, 32, Endian.little); // biBitCount, with BI_RGB as 0
}

void _readerMain(WorkerArgs args) {
  final (ready, out, width, _) = args;
  final frames = FrameSender(out, width);
  final user = DynamicLibrary.open('user32.dll');
  final gdi = DynamicLibrary.open('gdi32.dll');
  final kernel = DynamicLibrary.open('kernel32.dll');
  final findWindow = user
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  final threadProcess = user
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  final isWindow = user
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
  final isVisible = user
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible',
      );
  final clientRect = user
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Int32>),
        int Function(int, Pointer<Int32>)
      >('GetClientRect');
  final printWindow = user
      .lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32),
        int Function(int, int, int)
      >('PrintWindow');
  final createDc = gdi
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
        'CreateCompatibleDC',
      );
  final createDib = gdi
      .lookupFunction<
        IntPtr Function(
          IntPtr,
          Pointer<Uint8>,
          Uint32,
          Pointer<_Ptr>,
          IntPtr,
          Uint32,
        ),
        int Function(int, Pointer<Uint8>, int, Pointer<_Ptr>, int, int)
      >('CreateDIBSection');
  final select = gdi
      .lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>(
        'SelectObject',
      );
  final deleteObject = gdi
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'DeleteObject',
      );
  final deleteDc = gdi
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
  final flush = gdi.lookupFunction<Int32 Function(), int Function()>(
    'GdiFlush',
  );
  final processId = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetCurrentProcessId',
  );

  final self = processId();
  final viewClass = 'FLUTTERVIEW'.toNativeUtf16(allocator: calloc);
  final owner = calloc<Uint32>();
  final rect = calloc<Int32>(4);
  final info = calloc<Uint8>(bitmapInfoBytes);
  final bits = calloc<_Ptr>();
  final dc = createDc(0);
  var hwnd = 0, dib = 0, dibW = 0, dibH = 0, found = false;

  // Returns the first visible toplevel window of this process that holds a
  // Flutter view, or 0.
  int find() {
    for (
      var w = findWindow(0, 0, nullptr, nullptr);
      w != 0;
      w = findWindow(0, w, nullptr, nullptr)
    ) {
      threadProcess(w, owner);
      if (owner.value != self || isVisible(w) == 0) continue;
      if (findWindow(w, 0, viewClass, nullptr) != 0) return w;
    }
    return 0;
  }

  final port = ReceivePort();
  ready.send(port.sendPort);
  port.listen((m) {
    if (m == null) {
      if (dib != 0) deleteObject(dib);
      deleteDc(dc);
      port.close();
      return;
    }
    if (hwnd == 0 || isWindow(hwnd) == 0) {
      hwnd = find();
      if (hwnd == 0) {
        if (!found) frames.note('no shown window with a Flutter view');
        return;
      }
      found = true;
    }
    if (clientRect(hwnd, rect) == 0) return;
    final w = rect[2], h = rect[3];
    if (w <= 0 || h <= 0) return;
    if (w != dibW || h != dibH) {
      if (dib != 0) deleteObject(dib);
      fillBitmapInfo(info, w, h);
      dib = createDib(dc, info, 0, bits, 0, 0); // DIB_RGB_COLORS
      if (dib == 0) {
        frames.note('CreateDIBSection failed for $w x $h');
        dibW = dibH = 0;
        return;
      }
      select(dc, dib);
      (dibW, dibH) = (w, h);
    }
    // PW_CLIENTONLY and PW_RENDERFULLCONTENT.
    if (printWindow(hwnd, dc, 3) == 0) {
      frames.note('PrintWindow failed');
      return;
    }
    flush();
    final oh = scaledHeight(w, h, width);
    final rgba = Uint8List(width * oh * 4);
    final sum = scaleBgra8(
      bits.value.cast<Uint8>().asTypedList(w * h * 4),
      w,
      h,
      w * 4,
      rgba,
      width,
      oh,
    );
    frames.send(rgba, oh, sum);
  });
}
