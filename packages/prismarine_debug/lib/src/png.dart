import 'dart:io';
import 'dart:typed_data';

/// [rgba] (8-bit RGBA rows, top first) as a PNG: unfiltered rows, zlib
/// level 1 (fast). RGB unless [alpha] (then RGBA, straight alpha).
Uint8List encodePng(
  Uint8List rgba,
  int width,
  int height, {
  bool alpha = false,
}) {
  final channels = alpha ? 4 : 3;
  final rows = Uint8List((width * channels + 1) * height);
  var o = 0, i = 0;
  for (var y = 0; y < height; y++) {
    rows[o++] = 0;
    for (var x = 0; x < width; x++) {
      rows[o++] = rgba[i];
      rows[o++] = rgba[i + 1];
      rows[o++] = rgba[i + 2];
      if (alpha) rows[o++] = rgba[i + 3];
      i += 4;
    }
  }
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final head = ByteData(8)..setUint32(0, data.length);
    for (var k = 0; k < 4; k++) {
      head.setUint8(4 + k, type.codeUnitAt(k));
    }
    final t = head.buffer.asUint8List(4, 4);
    final crc = ByteData(4)..setUint32(0, _crc32([t, data]));
    out
      ..add(head.buffer.asUint8List())
      ..add(data)
      ..add(crc.buffer.asUint8List());
  }

  chunk(
    'IHDR',
    (ByteData(13)
          ..setUint32(0, width)
          ..setUint32(4, height)
          ..setUint8(8, 8) // bit depth
          ..setUint8(9, alpha ? 6 : 2)) // RGBA or RGB
        .buffer
        .asUint8List(),
  );
  chunk('IDAT', ZLibEncoder(level: 1).convert(rows));
  chunk('IEND', const []);
  return out.takeBytes();
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32(List<List<int>> parts) {
  var c = 0xffffffff;
  for (final p in parts) {
    for (final b in p) {
      c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    }
  }
  return c ^ 0xffffffff;
}
