// The GTK embedder of Flutter on Linux paints each composited frame into the
// view widget of its toplevel window. On an X11 display the UI isolate finds
// the X window of the toplevel and the rectangle of the view in it through
// GTK. A worker with its own X connection reads that rectangle with
// XGetImage. GDK ignores the X errors of a connection that it did not open,
// and XGetImage then returns no image.
//
// It works only with GDK on X11, also through Xwayland, and only with merged
// platform and UI threads. A window on a Wayland display of GDK has no reader.
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show calloc;

import 'window_surface.dart';
import 'window_surface_pixels.dart';

typedef _Ptr = Pointer<Void>;
typedef _PtrFn = _Ptr Function(_Ptr);
typedef _IntFn = int Function(_Ptr);

/// The X11 window of the GTK toplevel on Linux.
class X11SurfaceSource implements SurfaceSource {
  X11SurfaceSource._(DynamicLibrary lib)
    : _toplevels = lib.lookupFunction<_Ptr Function(), _Ptr Function()>(
        'gtk_window_list_toplevels',
      ),
      _listFree = lib.lookupFunction<Void Function(_Ptr), void Function(_Ptr)>(
        'g_list_free',
      ),
      _visible = lib.lookupFunction<Int32 Function(_Ptr), _IntFn>(
        'gtk_widget_get_visible',
      ),
      _windowType = lib.lookupFunction<Int32 Function(_Ptr), _IntFn>(
        'gtk_window_get_window_type',
      ),
      _child = lib.lookupFunction<_Ptr Function(_Ptr), _PtrFn>(
        'gtk_bin_get_child',
      ),
      _gdkWindow = lib.lookupFunction<_Ptr Function(_Ptr), _PtrFn>(
        'gtk_widget_get_window',
      ),
      _xid = lib.lookupFunction<UnsignedLong Function(_Ptr), _IntFn>(
        'gdk_x11_window_get_xid',
      ),
      _isA = lib
          .lookupFunction<Int32 Function(_Ptr, Size), int Function(_Ptr, int)>(
            'g_type_check_instance_is_a',
          ),
      _x11WindowType = lib.lookupFunction<Size Function(), int Function()>(
        'gdk_x11_window_get_type',
      )(),
      _allocation = lib
          .lookupFunction<
            Void Function(_Ptr, Pointer<Int32>),
            void Function(_Ptr, Pointer<Int32>)
          >('gtk_widget_get_allocation'),
      _scale = lib.lookupFunction<Int32 Function(_Ptr), _IntFn>(
        'gtk_widget_get_scale_factor',
      );

  /// Returns the source, or null when GDK has no X11 display or the UI
  /// isolate is not on the thread of the GTK main loop.
  static X11SurfaceSource? open() {
    final lib = DynamicLibrary.process();
    if (!lib.providesSymbol('gdk_x11_display_get_type') ||
        !lib.providesSymbol('gtk_window_list_toplevels')) {
      return null;
    }
    final defaultDisplay = lib.lookupFunction<_Ptr Function(), _Ptr Function()>(
      'gdk_display_get_default',
    );
    final x11DisplayType = lib.lookupFunction<Size Function(), int Function()>(
      'gdk_x11_display_get_type',
    );
    final isA = lib
        .lookupFunction<Int32 Function(_Ptr, Size), int Function(_Ptr, int)>(
          'g_type_check_instance_is_a',
        );
    final mainContext = lib.lookupFunction<_Ptr Function(), _Ptr Function()>(
      'g_main_context_default',
    );
    final isOwner = lib.lookupFunction<Int32 Function(_Ptr), _IntFn>(
      'g_main_context_is_owner',
    );
    final display = defaultDisplay();
    if (display == nullptr || isA(display, x11DisplayType()) == 0) return null;
    if (isOwner(mainContext()) == 0) return null;
    return X11SurfaceSource._(lib);
  }

  final _Ptr Function() _toplevels;
  final void Function(_Ptr) _listFree;
  final _IntFn _visible, _windowType, _xid, _scale;
  final _PtrFn _child, _gdkWindow;
  final int Function(_Ptr, int) _isA;
  final int _x11WindowType;
  final void Function(_Ptr, Pointer<Int32>) _allocation;

  // The x, y, width and height of a GtkAllocation, kept for the life of the
  // isolate.
  late final Pointer<Int32> _rect = calloc<Int32>(4);
  final _last = Int64List(5);

  @override
  void Function(WorkerArgs) get worker => _readerMain;

  @override
  Object? get workerArg => null;

  /// Returns a list of the X window and the rectangle of the view when they
  /// changed since the last take, 0 when they did not and null without a
  /// shown window.
  @override
  Object? take() {
    final (top, view) = _shownWindow();
    if (top == nullptr) return null;
    final gdk = _gdkWindow(top);
    if (gdk == nullptr || _isA(gdk, _x11WindowType) == 0) return null;
    _allocation(view, _rect);
    final s = _scale(view);
    final xid = _xid(gdk);
    final x = _rect[0] * s, y = _rect[1] * s;
    final w = _rect[2] * s, h = _rect[3] * s;
    if (w <= 0 || h <= 0) return null;
    if (_last[0] == xid &&
        _last[1] == x &&
        _last[2] == y &&
        _last[3] == w &&
        _last[4] == h) {
      return 0;
    }
    _last
      ..[0] = xid
      ..[1] = x
      ..[2] = y
      ..[3] = w
      ..[4] = h;
    return [xid, x, y, w, h];
  }

  // Returns the first visible toplevel of the normal type with a child and
  // that child, or nullptr twice.
  (_Ptr, _Ptr) _shownWindow() {
    final list = _toplevels();
    var top = nullptr.cast<Void>(), view = nullptr.cast<Void>();
    // A GList node holds the data and then the next node.
    for (
      var n = list;
      n != nullptr;
      n = Pointer<_Ptr>.fromAddress(n.address + 8).value
    ) {
      final w = n.cast<_Ptr>().value;
      if (_visible(w) == 0 || _windowType(w) != 0) continue;
      final c = _child(w);
      if (c == nullptr) continue;
      (top, view) = (w, c);
      break;
    }
    if (list != nullptr) _listFree(list);
    return (top, view);
  }

  @override
  String describe() => 'no shown GTK toplevel window on X11';
}

void _readerMain(WorkerArgs args) {
  final (ready, out, width, _) = args;
  final frames = FrameSender(out, width);
  final x11 = DynamicLibrary.open('libX11.so.6');
  final openDisplay = x11.lookupFunction<_PtrFn, _PtrFn>('XOpenDisplay');
  final getImage = x11
      .lookupFunction<
        _Ptr Function(
          _Ptr,
          UnsignedLong,
          Int32,
          Int32,
          Uint32,
          Uint32,
          UnsignedLong,
          Int32,
        ),
        _Ptr Function(_Ptr, int, int, int, int, int, int, int)
      >('XGetImage');
  final destroyImage = x11.lookupFunction<Int32 Function(_Ptr), _IntFn>(
    'XDestroyImage',
  );
  final closeDisplay = x11.lookupFunction<Int32 Function(_Ptr), _IntFn>(
    'XCloseDisplay',
  );
  final display = openDisplay(nullptr);
  if (display == nullptr) frames.note('the X display cannot be opened');
  const allPlanes = -1, zPixmap = 2;
  var xid = 0, x = 0, y = 0, w = 0, h = 0;
  final port = ReceivePort();
  ready.send(port.sendPort);
  port.listen((m) {
    if (m == null) {
      if (display != nullptr) closeDisplay(display);
      port.close();
      return;
    }
    if (m is List) {
      xid = m[0] as int;
      x = m[1] as int;
      y = m[2] as int;
      w = m[3] as int;
      h = m[4] as int;
    }
    if (display == nullptr || xid == 0) return;
    final image = getImage(display, xid, x, y, w, h, allPlanes, zPixmap);
    if (image == nullptr) {
      frames.note('XGetImage returned no image of $w x $h at $x, $y');
      return;
    }
    try {
      final f = X11Image(image.cast());
      if (!isX11Bgrx(
        f.bitsPerPixel,
        f.byteOrder,
        f.redMask,
        f.greenMask,
        f.blueMask,
      )) {
        frames.note('X11 image of ${f.bitsPerPixel} bits per pixel');
        return;
      }
      final oh = scaledHeight(f.width, f.height, width);
      final rgba = Uint8List(width * oh * 4);
      final sum = scaleBgra8(
        f.data.asTypedList(f.bytesPerLine * f.height),
        f.width,
        f.height,
        f.bytesPerLine,
        rgba,
        width,
        oh,
      );
      frames.send(rgba, oh, sum);
    } finally {
      destroyImage(image);
    }
  });
}

/// The fields of an `XImage` of Xlib on a 64-bit system.
extension type X11Image(Pointer<Uint8> _p) {
  int _i32(int at) => Pointer<Int32>.fromAddress(_p.address + at).value;
  int _u64(int at) => Pointer<Uint64>.fromAddress(_p.address + at).value;

  int get width => _i32(0);
  int get height => _i32(4);
  Pointer<Uint8> get data => Pointer<Uint8>.fromAddress(_u64(16));
  int get byteOrder => _i32(24);
  int get bytesPerLine => _i32(44);
  int get bitsPerPixel => _i32(48);
  int get redMask => _u64(56);
  int get greenMask => _u64(64);
  int get blueMask => _u64(72);
}
