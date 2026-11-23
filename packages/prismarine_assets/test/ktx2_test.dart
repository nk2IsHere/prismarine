import 'dart:convert';
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:test/test.dart';

/// The key-value data of a KTX2 file, with the NUL ends removed.
Map<String, String> keyValues(Uint8List ktx) {
  final d = ByteData.sublistView(ktx);
  final at = d.getUint32(56, Endian.little);
  final end = at + d.getUint32(60, Endian.little);
  final out = <String, String>{};
  for (var p = at; p + 4 <= end;) {
    final n = d.getUint32(p, Endian.little);
    final pair = ktx.sublist(p + 4, p + 4 + n);
    final split = pair.indexOf(0);
    out[utf8.decode(pair.sublist(0, split))] = utf8.decode(
      pair.sublist(split + 1, n - 1),
    );
    p += 4 + ((n + 3) & ~3);
  }
  return out;
}

void main() {
  test('levels are stored smallest first, each aligned to its block', () {
    final bytes = encodeKtx2(
      format: Ktx2Format.bc3,
      width: 8,
      height: 8,
      levels: [Uint8List(64), Uint8List(16)],
    );
    final d = ByteData.sublistView(bytes);
    final big = d.getUint64(80, Endian.little);
    final small = d.getUint64(80 + 24, Endian.little);
    expect(small, lessThan(big));
    expect(small % 16, 0);
    expect(big % 16, 0);
    expect(bytes.sublist(1, 7), 'KTX 20'.codeUnits);
    expect(d.getUint32(12, Endian.little), Ktx2Format.bc3.vk);
  });

  test('the key-value data holds the writer and the values in key order', () {
    Uint8List encode({String? writer}) => writer == null
        ? encodeKtx2(
            format: Ktx2Format.rgba8,
            width: 1,
            height: 1,
            levels: [Uint8List(4)],
            values: {'b': '2', 'a': '1'},
          )
        : encodeKtx2(
            format: Ktx2Format.rgba8,
            width: 1,
            height: 1,
            levels: [Uint8List(4)],
            values: {'b': '2', 'a': '1'},
            writer: writer,
          );
    expect(keyValues(encode()), {
      'KTXwriter': 'prismarine_assets',
      'a': '1',
      'b': '2',
    });
    expect(keyValues(encode()).keys, ['KTXwriter', 'a', 'b']);
    expect(keyValues(encode(writer: 'tool'))['KTXwriter'], 'tool');
  });
}
