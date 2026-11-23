import 'dart:typed_data';

int _expand5(int v) => (v << 3) | (v >> 2);
int _expand6(int v) => (v << 2) | (v >> 4);

List<List<int>> _palette(int c0, int c1, {required bool forceFour}) {
  List<int> rgb(int c) => [
    _expand5((c >> 11) & 0x1f),
    _expand6((c >> 5) & 0x3f),
    _expand5(c & 0x1f),
  ];
  final a = rgb(c0), b = rgb(c1);
  if (forceFour || c0 > c1) {
    return [
      [...a, 255],
      [...b, 255],
      [for (var i = 0; i < 3; i++) (2 * a[i] + b[i] + 1) ~/ 3, 255],
      [for (var i = 0; i < 3; i++) (a[i] + 2 * b[i] + 1) ~/ 3, 255],
    ];
  }
  return [
    [...a, 255],
    [...b, 255],
    [for (var i = 0; i < 3; i++) (a[i] + b[i] + 1) ~/ 2, 255],
    [0, 0, 0, 0],
  ];
}

void _colorBlock(
  ByteData bd,
  int at,
  Uint8List out,
  int w,
  int h,
  int bx,
  int by, {
  required bool bc3,
}) {
  final c0 = bd.getUint16(at, Endian.little),
      c1 = bd.getUint16(at + 2, Endian.little);
  final idx = bd.getUint32(at + 4, Endian.little);
  final pal = _palette(c0, c1, forceFour: bc3);
  for (var p = 0; p < 16; p++) {
    final x = bx * 4 + (p & 3), y = by * 4 + (p >> 2);
    if (x >= w || y >= h) continue;
    final c = pal[(idx >> (2 * p)) & 3];
    final o = (y * w + x) * 4;
    out[o] = c[0];
    out[o + 1] = c[1];
    out[o + 2] = c[2];
    if (!bc3) out[o + 3] = c[3];
  }
}

/// BC1 (DXT1) blocks → RGBA8, cropping partial blocks.
Uint8List decodeBc1(Uint8List blocks, int width, int height) {
  final bw = (width + 3) ~/ 4, bh = (height + 3) ~/ 4;
  if (blocks.length < bw * bh * 8) throw ArgumentError('BC1 data too short');
  final out = Uint8List(width * height * 4);
  final bd = ByteData.sublistView(blocks);
  for (var by = 0; by < bh; by++) {
    for (var bx = 0; bx < bw; bx++) {
      _colorBlock(
        bd,
        (by * bw + bx) * 8,
        out,
        width,
        height,
        bx,
        by,
        bc3: false,
      );
    }
  }
  return out;
}

/// BC3 (DXT5) blocks → RGBA8.
Uint8List decodeBc3(Uint8List blocks, int width, int height) {
  final bw = (width + 3) ~/ 4, bh = (height + 3) ~/ 4;
  if (blocks.length < bw * bh * 16) throw ArgumentError('BC3 data too short');
  final out = Uint8List(width * height * 4);
  final bd = ByteData.sublistView(blocks);
  for (var by = 0; by < bh; by++) {
    for (var bx = 0; bx < bw; bx++) {
      final at = (by * bw + bx) * 16;
      final a0 = blocks[at], a1 = blocks[at + 1];
      var bits = 0;
      for (var i = 0; i < 6; i++) {
        bits |= blocks[at + 2 + i] << (8 * i);
      }
      final alphas = a0 > a1
          ? [
              a0,
              a1,
              for (var i = 1; i < 7; i++) ((7 - i) * a0 + i * a1 + 3) ~/ 7,
            ]
          : [
              a0,
              a1,
              for (var i = 1; i < 5; i++) ((5 - i) * a0 + i * a1 + 2) ~/ 5,
              0,
              255,
            ];
      _colorBlock(bd, at + 8, out, width, height, bx, by, bc3: true);
      for (var p = 0; p < 16; p++) {
        final x = bx * 4 + (p & 3), y = by * 4 + (p >> 2);
        if (x >= width || y >= height) continue;
        out[(y * width + x) * 4 + 3] = alphas[(bits >> (3 * p)) & 7];
      }
    }
  }
  return out;
}
