import 'dart:io';
import 'dart:typed_data';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:test/test.dart';

Uint8List bc1Block(int c0, int c1, int indices) {
  final b = ByteData(8)
    ..setUint16(0, c0, Endian.little)
    ..setUint16(2, c1, Endian.little)
    ..setUint32(4, indices, Endian.little);
  return b.buffer.asUint8List();
}

List<int> px(Uint8List rgba, int w, int x, int y) =>
    rgba.sublist((y * w + x) * 4, (y * w + x) * 4 + 4);

void main() {
  group('BC1', () {
    test('4-colour block: endpoints and interpolants (c0 > c1)', () {
      // c0 = pure red (0xF800), c1 = pure blue (0x001F); pixel i uses index i % 4 → row-major, LSB first
      final rgba = decodeBc1(
        bc1Block(0xF800, 0x001F, 0xE4E4E4E4),
        4,
        4,
      ); // indices 0,1,2,3 per row
      expect(px(rgba, 4, 0, 0), [255, 0, 0, 255]);
      expect(px(rgba, 4, 1, 0), [0, 0, 255, 255]);
      expect(px(rgba, 4, 2, 0), [170, 0, 85, 255]);
      expect(px(rgba, 4, 3, 0), [85, 0, 170, 255]);
    });
    test('3-colour block with transparent black (c0 <= c1)', () {
      final rgba = decodeBc1(
        bc1Block(0x001F, 0xF800, 0xFFFFFFFF),
        4,
        4,
      ); // all index 3
      expect(px(rgba, 4, 2, 2), [0, 0, 0, 0]);
    });
    test('BC1 6x5 crops partial blocks', () {
      final blocks = Uint8List.fromList([
        for (var i = 0; i < 4; i++) ...bc1Block(0xF800, 0xF800, 0),
      ]);
      final rgba = decodeBc1(blocks, 6, 5);
      expect(rgba.length, 6 * 5 * 4);
      expect(px(rgba, 6, 5, 4), [255, 0, 0, 255]);
    });
  });

  test('BC3 alpha: 8-alpha mode endpoints and interpolation', () {
    // alpha0=255, alpha1=0; index bits: pixel0=0 (255), pixel1=1 (0), pixel2=2 ((6*255+1*0)/7=219)
    final alpha = ByteData(8)
      ..setUint8(0, 255)
      ..setUint8(1, 0);
    final bits = 0 | (1 << 3) | (2 << 6);
    for (var i = 0; i < 6; i++) {
      alpha.setUint8(2 + i, (bits >> (8 * i)) & 0xff);
    }
    final block = Uint8List.fromList([
      ...alpha.buffer.asUint8List(),
      ...bc1Block(0xFFFF, 0x0000, 0),
    ]);
    final rgba = decodeBc3(block, 4, 4);
    expect(px(rgba, 4, 0, 0)[3], 255);
    expect(px(rgba, 4, 1, 0)[3], 0);
    expect(px(rgba, 4, 2, 0)[3], 219);
    expect(px(rgba, 4, 0, 0).sublist(0, 3), [255, 255, 255]);
  });

  test('PNG: signature, IHDR, IDAT inflates to filtered rows, CRCs valid', () {
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 128]); // 2x1
    final png = encodePng(2, 1, rgba);
    expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final bd = ByteData.sublistView(png);
    var p = 8;
    final chunks = <String, Uint8List>{};
    while (p < png.length) {
      final len = bd.getUint32(p);
      final type = String.fromCharCodes(png.sublist(p + 4, p + 8));
      chunks[type] = png.sublist(p + 8, p + 8 + len);
      expect(
        bd.getUint32(p + 8 + len),
        crc32(png.sublist(p + 4, p + 8 + len)),
        reason: '$type CRC',
      );
      p += 12 + len;
    }
    expect(chunks.keys, ['IHDR', 'IDAT', 'IEND']);
    expect(ByteData.sublistView(chunks['IHDR']!).getUint32(0), 2);
    expect(chunks['IHDR']![8], 8); // bit depth
    expect(chunks['IHDR']![9], 6); // RGBA
    expect(ZLibDecoder().convert(chunks['IDAT']!), [0, ...rgba]);
  });
}
