import 'dart:math' as math;
import 'dart:typed_data';

/// The kind of data in a texture, which decides the filter of its mips.
enum TextureUse {
  /// Colour in sRGB, such as a base colour or an emissive texture. Mips are
  /// filtered in linear light. Alpha is linear.
  color,

  /// Linear data, such as metallic and roughness or occlusion.
  data,

  /// A tangent-space normal map. Each mip texel is renormalized.
  normal,
}

/// Halves an RGBA8 image of [width] by [height] with a 2 by 2 box filter.
/// A side of 1 stays 1. An odd side drops its last row or column.
Uint8List halveRgba8(Uint8List rgba, int width, int height, TextureUse use) {
  final w = math.max(1, width >> 1), h = math.max(1, height >> 1);
  final out = Uint8List(w * h * 4);
  final dx = width > 1 ? 1 : 0, dy = height > 1 ? 1 : 0;
  final toLinear = _toLinear, toSrgb = _toSrgb;
  final quad = Int32List(4);
  for (var y = 0; y < h; y++) {
    final r0 = (2 * y) * width, r1 = (2 * y + dy) * width;
    for (var x = 0; x < w; x++) {
      final a = (r0 + 2 * x) * 4, b = (r0 + 2 * x + dx) * 4;
      final c = (r1 + 2 * x) * 4, e = (r1 + 2 * x + dx) * 4;
      final o = (y * w + x) * 4;
      switch (use) {
        case TextureUse.color:
          for (var k = 0; k < 3; k++) {
            final v =
                (toLinear[rgba[a + k]] +
                    toLinear[rgba[b + k]] +
                    toLinear[rgba[c + k]] +
                    toLinear[rgba[e + k]]) *
                0.25;
            out[o + k] = toSrgb[(v * 4095 + 0.5).toInt()];
          }
          out[o + 3] =
              (rgba[a + 3] + rgba[b + 3] + rgba[c + 3] + rgba[e + 3] + 2) >> 2;
        case TextureUse.data:
          for (var k = 0; k < 4; k++) {
            out[o + k] =
                (rgba[a + k] + rgba[b + k] + rgba[c + k] + rgba[e + k] + 2) >>
                2;
          }
        case TextureUse.normal:
          var nx = 0.0, ny = 0.0, nz = 0.0;
          quad
            ..[0] = a
            ..[1] = b
            ..[2] = c
            ..[3] = e;
          for (var q = 0; q < 4; q++) {
            final p = quad[q];
            nx += rgba[p] / 127.5 - 1;
            ny += rgba[p + 1] / 127.5 - 1;
            nz += rgba[p + 2] / 127.5 - 1;
          }
          final len = math.sqrt(nx * nx + ny * ny + nz * nz);
          final s = len > 1e-6 ? 1 / len : 0.0;
          if (s == 0) nz = 1;
          out[o] = ((nx * s + 1) * 127.5).round().clamp(0, 255);
          out[o + 1] = ((ny * s + 1) * 127.5).round().clamp(0, 255);
          out[o + 2] = (((s == 0 ? 1 : nz * s) + 1) * 127.5).round().clamp(
            0,
            255,
          );
          out[o + 3] =
              (rgba[a + 3] + rgba[b + 3] + rgba[c + 3] + rgba[e + 3] + 2) >> 2;
      }
    }
  }
  return out;
}

/// Scales an RGBA8 image down by halves until no side is larger than
/// [maxSize], then makes every mip level down to 1 by 1. Returns the size of
/// the first level and the levels, largest first.
(int, int, List<Uint8List>) mipChainRgba8(
  Uint8List rgba,
  int width,
  int height,
  TextureUse use, {
  int maxSize = 1 << 30,
}) {
  var w = width, h = height, img = rgba;
  while (w > maxSize || h > maxSize) {
    img = halveRgba8(img, w, h, use);
    w = math.max(1, w >> 1);
    h = math.max(1, h >> 1);
  }
  final levels = [img];
  final top = (w, h);
  while (w > 1 || h > 1) {
    img = halveRgba8(img, w, h, use);
    w = math.max(1, w >> 1);
    h = math.max(1, h >> 1);
    levels.add(img);
  }
  return (top.$1, top.$2, levels);
}

double _srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _linearToSrgb(double c) => c <= 0.0031308
    ? c * 12.92
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

final _toLinear = Float64List.fromList([
  for (var i = 0; i < 256; i++) _srgbToLinear(i / 255),
]);

final _toSrgb = Uint8List.fromList([
  for (var i = 0; i < 4096; i++) (_linearToSrgb(i / 4095) * 255).round(),
]);
