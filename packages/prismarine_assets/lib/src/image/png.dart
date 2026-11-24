import 'dart:io';
import 'dart:typed_data';

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
}, growable: false);

/// Returns the CRC-32 of [bytes] in the ISO-HDLC form that PNG chunks use.
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Encodes the RGBA8 pixels [rgba] of an image of [width] by [height], rows
/// from the top, as a PNG of 8-bit channels and unfiltered rows.
///
/// The PNG is RGBA with straight alpha when [alpha] is true and RGB without
/// the alpha channel otherwise. [level] is the zlib level of the image data,
/// from 1 for the fastest encode to 9 for the smallest file. The same input
/// and options give the same bytes on every OS.
Uint8List encodePng(
  int width,
  int height,
  Uint8List rgba, {
  bool alpha = true,
  int level = 9,
}) {
  if (rgba.length != width * height * 4) {
    throw ArgumentError('rgba length ${rgba.length} != $width x $height x 4');
  }
  final channels = alpha ? 4 : 3;
  final stride = width * channels + 1;
  final rows = Uint8List(stride * height);
  if (alpha) {
    for (var y = 0; y < height; y++) {
      rows.setRange(y * stride + 1, (y + 1) * stride, rgba, y * width * 4);
    }
  } else {
    var o = 0, i = 0;
    for (var y = 0; y < height; y++) {
      o++;
      for (var x = 0; x < width; x++) {
        rows[o++] = rgba[i];
        rows[o++] = rgba[i + 1];
        rows[o++] = rgba[i + 2];
        i += 4;
      }
    }
  }
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = Uint8List(4 + data.length)
      ..setAll(0, type.codeUnits)
      ..setAll(4, data);
    out
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, data.length))
      ..add(body)
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, crc32(body)));
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, alpha ? 6 : 2);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder(level: level).convert(rows));
  chunk('IEND', const []);
  return out.takeBytes();
}
