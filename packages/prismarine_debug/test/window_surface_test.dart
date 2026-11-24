// The logic of the window surface reader that does not need a window, on
// every platform.
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/src/window_surface.dart';
import 'package:prismarine_debug/src/window_surface_pixels.dart';
import 'package:prismarine_debug/src/window_surface_windows.dart';
import 'package:prismarine_debug/src/window_surface_x11.dart';

void main() {
  // A 4 by 2 BGRX picture with 4 bytes of padding after each row. The pixel
  // at x, y has B = 10 y + x, G = 100 + x and R = 200 + y.
  Uint8List picture() {
    final b = Uint8List(2 * 20);
    for (var y = 0; y < 2; y++) {
      for (var x = 0; x < 4; x++) {
        b.setAll(y * 20 + x * 4, [10 * y + x, 100 + x, 200 + y, 7]);
      }
    }
    return b;
  }

  test('BGRX rows with padding scale to opaque RGBA', () {
    final out = Uint8List(2 * 1 * 4);
    scaleBgra8(picture(), 4, 2, 20, out, 2, 1);
    expect(out, [200, 100, 0, 255, 200, 102, 2, 255]);
    final full = Uint8List(4 * 2 * 4);
    scaleBgra8(picture(), 4, 2, 20, full, 4, 2);
    expect(full.sublist(4 * 7), [201, 103, 13, 255]);
  });

  test('the checksum changes with the picture and only with it', () {
    final a = Uint8List(16), b = Uint8List(16);
    final p = picture();
    final s1 = scaleBgra8(p, 4, 2, 20, a, 2, 2);
    expect(scaleBgra8(p, 4, 2, 20, b, 2, 2), s1);
    p[0] = 99;
    expect(scaleBgra8(p, 4, 2, 20, b, 2, 2), isNot(s1));
  });

  test('extended-range 10-bit channels map 384 to 0 and 894 to 255', () {
    final src = Uint16List.fromList([
      384 << 6, 639 << 6, 894 << 6, 1023 << 6, // B, G, R, A
    ]);
    final out = Uint8List(4);
    scaleBgra10Xr(src, 1, 1, 8, out, 1, 1);
    expect(out, [255, 128, 0, 255]);
    expect(extendedRange10[100], 0);
    expect(extendedRange10[1000], 255);
  });

  test('a copy keeps the aspect of the window', () {
    expect(scaledHeight(1920, 1080, 640), 360);
    expect(scaledHeight(1800, 1037, 640), 369);
  });

  test('X11 images of 32 bits with BGRX bytes are read', () {
    expect(isX11Bgrx(32, 0, 0xff0000, 0xff00, 0xff), isTrue);
    expect(isX11Bgrx(32, 1, 0xff0000, 0xff00, 0xff), isFalse);
    expect(isX11Bgrx(32, 0, 0xff, 0xff00, 0xff0000), isFalse);
    expect(isX11Bgrx(16, 0, 0xf800, 0x7e0, 0x1f), isFalse);
  });

  test('the fields of an XImage of a 64-bit Xlib', () {
    final p = calloc<Uint8>(136);
    final b = ByteData.sublistView(p.asTypedList(136));
    b
      ..setInt32(0, 1920, Endian.host)
      ..setInt32(4, 1080, Endian.host)
      ..setUint64(16, 0x1000, Endian.host)
      ..setInt32(24, 0, Endian.host)
      ..setInt32(40, 24, Endian.host) // depth
      ..setInt32(44, 7680, Endian.host)
      ..setInt32(48, 32, Endian.host)
      ..setUint64(56, 0xff0000, Endian.host)
      ..setUint64(64, 0xff00, Endian.host)
      ..setUint64(72, 0xff, Endian.host);
    final i = X11Image(p);
    expect((i.width, i.height, i.bytesPerLine), (1920, 1080, 7680));
    expect(i.data.address, 0x1000);
    expect(
      isX11Bgrx(
        i.bitsPerPixel,
        i.byteOrder,
        i.redMask,
        i.greenMask,
        i.blueMask,
      ),
      isTrue,
    );
    calloc.free(p);
  });

  test('the bitmap header of a top-down 32-bit DIB', () {
    final p = calloc<Uint8>(bitmapInfoBytes);
    p[30] = 9;
    fillBitmapInfo(p, 1280, 720);
    final b = ByteData.sublistView(p.asTypedList(bitmapInfoBytes));
    expect(b.getUint32(0, Endian.little), 40);
    expect(b.getInt32(4, Endian.little), 1280);
    expect(b.getInt32(8, Endian.little), -720);
    expect(b.getUint16(12, Endian.little), 1);
    expect(b.getUint16(14, Endian.little), 32);
    expect(p.asTypedList(bitmapInfoBytes).sublist(16), everyElement(0));
    calloc.free(p);
  });

  test(
    'a sender drops a copy equal to the last one and keeps two notes',
    () async {
      final port = ReceivePort();
      final got = <Object?>[];
      port.listen(got.add);
      final s = FrameSender(port.sendPort, 2)
        ..send(Uint8List(8), 1, 5)
        ..send(Uint8List(8), 1, 5)
        ..send(Uint8List(8), 1, 6)
        ..note('a')
        ..note('b')
        ..note('c');
      expect(s, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      port.close();
      expect(got.whereType<List>().length, 2);
      expect(got.whereType<String>(), ['a', 'b']);
      expect((got.first as List).sublist(1), [2, 1]);
    },
  );
}
