import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

void main() {
  test('encodePng(alpha: true): an RGBA PNG (a UI layer keeps its alpha)', () {
    final rgba = Uint8List.fromList([
      for (var i = 0; i < 2; i++) ...[i * 10, i * 10 + 1, i * 10 + 2, 100 + i],
    ]);
    final png = encodePng(rgba, 2, 1, alpha: true);
    final b = ByteData.sublistView(png);
    expect((png[24], png[25]), (8, 6));
    final idatLen = b.getUint32(33);
    final rows = ZLibDecoder().convert(png.sublist(41, 41 + idatLen));
    expect(rows, [0, 0, 1, 2, 100, 10, 11, 12, 101]);
  });

  test('encodePng: an RGB PNG of unfiltered rows (alpha dropped)', () {
    final rgba = Uint8List.fromList([
      for (var i = 0; i < 6; i++) ...[i * 10, i * 10 + 1, i * 10 + 2, i],
    ]);
    final png = encodePng(rgba, 3, 2);
    expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final b = ByteData.sublistView(png);
    expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
    expect((b.getUint32(16), b.getUint32(20)), (3, 2));
    expect((png[24], png[25]), (8, 2));
    // The CRC of IHDR over type and data, then the well-known CRC of IEND.
    expect(b.getUint32(29), 0x1216f14d);
    expect(png.sublist(png.length - 12), [
      0,
      0,
      0,
      0,
      0x49,
      0x45,
      0x4e,
      0x44,
      0xae,
      0x42,
      0x60,
      0x82,
    ]);
    final idatLen = b.getUint32(33);
    expect(String.fromCharCodes(png.sublist(37, 41)), 'IDAT');
    final rows = ZLibDecoder().convert(png.sublist(41, 41 + idatLen));
    expect(rows, [
      0,
      0,
      1,
      2,
      10,
      11,
      12,
      20,
      21,
      22,
      0,
      30,
      31,
      32,
      40,
      41,
      42,
      50,
      51,
      52,
    ]);
  });
}
