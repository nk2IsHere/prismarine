import 'dart:typed_data';

/// Returns the height of a copy [outWidth] wide of a picture of [width] by
/// [height] with the same aspect.
int scaledHeight(int width, int height, int outWidth) =>
    (height * outWidth / width).round();

/// Scales a picture of [width] by [height] in [src] to the RGBA8 pixels of
/// [out], [outWidth] by [outHeight], by nearest sampling with opaque alpha.
/// Returns a checksum of the colours of [out].
///
/// The pixels of [src] have B, G, R and a fourth byte that is not read. Each
/// of its rows starts [rowBytes] bytes after the one before.
int scaleBgra8(
  Uint8List src,
  int width,
  int height,
  int rowBytes,
  Uint8List out,
  int outWidth,
  int outHeight,
) {
  var sum = 0;
  for (var y = 0; y < outHeight; y++) {
    final row = (y * height ~/ outHeight) * rowBytes;
    for (var x = 0; x < outWidth; x++) {
      final o = (y * outWidth + x) * 4;
      final p = row + (x * width ~/ outWidth) * 4;
      out[o] = src[p + 2];
      out[o + 1] = src[p + 1];
      out[o + 2] = src[p];
      out[o + 3] = 255;
      sum = (sum * 31 + out[o] + out[o + 1] + out[o + 2]) & 0x3fffffff;
    }
  }
  return sum;
}

/// The 8-bit values of the 10-bit channels of an extended-range picture, in
/// which 384 is 0.0 and 894 is 1.0.
final Uint8List extendedRange10 = () {
  final xr = Uint8List(1024);
  for (var v = 0; v < 1024; v++) {
    xr[v] = (((v - 384) / 510).clamp(0.0, 1.0) * 255).round();
  }
  return xr;
}();

/// Scales a picture of [width] by [height] with 16-bit B, G, R and A in
/// [src16] to [out] as [scaleBgra8] does. Each channel has its 10-bit value
/// of [extendedRange10] in the top bits. Each row starts [rowBytes] bytes
/// after the one before.
int scaleBgra10Xr(
  Uint16List src16,
  int width,
  int height,
  int rowBytes,
  Uint8List out,
  int outWidth,
  int outHeight,
) {
  final xr = extendedRange10;
  var sum = 0;
  for (var y = 0; y < outHeight; y++) {
    final row = (y * height ~/ outHeight) * rowBytes;
    for (var x = 0; x < outWidth; x++) {
      final o = (y * outWidth + x) * 4;
      final p = (row + (x * width ~/ outWidth) * 8) >> 1;
      out[o] = xr[src16[p + 2] >> 6];
      out[o + 1] = xr[src16[p + 1] >> 6];
      out[o + 2] = xr[src16[p] >> 6];
      out[o + 3] = 255;
      sum = (sum * 31 + out[o] + out[o + 1] + out[o + 2]) & 0x3fffffff;
    }
  }
  return sum;
}

/// Returns true when an X11 image of the ZPixmap format with [bitsPerPixel],
/// [byteOrder] and the masks has the B, G, R, X bytes that [scaleBgra8]
/// reads. A [byteOrder] of 0 is LSBFirst.
bool isX11Bgrx(
  int bitsPerPixel,
  int byteOrder,
  int redMask,
  int greenMask,
  int blueMask,
) =>
    bitsPerPixel == 32 &&
    byteOrder == 0 &&
    redMask == 0xff0000 &&
    greenMask == 0xff00 &&
    blueMask == 0xff;
