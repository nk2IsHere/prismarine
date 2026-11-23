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

/// Encodes the RGBA8 pixels [rgba] of an image of [width] by [height] as a
/// PNG. Each row has filter 0 and the image data has zlib level 9.
Uint8List encodePng(int width, int height, Uint8List rgba) {
  if (rgba.length != width * height * 4) {
    throw ArgumentError('rgba length ${rgba.length} != $width x $height x 4');
  }
  final raw = Uint8List(height * (width * 4 + 1));
  for (var y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0;
    raw.setRange(
      y * (width * 4 + 1) + 1,
      (y + 1) * (width * 4 + 1),
      rgba,
      y * width * 4,
    );
  }
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final head = Uint8List(4)..buffer.asByteData().setUint32(0, data.length);
    final body = [...type.codeUnits, ...data];
    out
      ..add(head)
      ..add(body)
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, crc32(body)));
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw));
  chunk('IEND', const []);
  return out.toBytes();
}
