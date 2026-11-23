import 'dart:convert';
import 'dart:typed_data';

/// Encodes a texture as KTX 2.0 with its texels as given, every level, layer
/// and face. The file has a basic data format descriptor. The key-value data holds
/// [values] and the key `KTXwriter` with [writer].
///
/// [levels] holds each mip level, largest first. A level holds its images in
/// the order of KTX2, by layer, then by face, then by depth slice.
Uint8List encodeKtx2({
  required Ktx2Format format,
  required int width,
  required int height,
  int depth = 0,
  int layers = 0,
  int faces = 1,
  required List<Uint8List> levels,
  Map<String, String> values = const {},
  String writer = 'prismarine_assets',
}) {
  final dfd = _dfd(format);
  final kvd = _kvd({'KTXwriter': writer, ...values});
  const header = 80;
  final index = levels.length * 24;
  final dfdAt = header + index;
  final kvdAt = dfdAt + dfd.length;
  var at = kvdAt + kvd.length;
  // The levels are stored smallest first. Each starts on a multiple of the
  // least common multiple of the block size and 4, as the spec asks for
  // these formats.
  final align = _lcm4(format.blockBytes);
  final offsets = List<int>.filled(levels.length, 0);
  for (var k = levels.length - 1; k >= 0; k--) {
    at = (at + align - 1) ~/ align * align;
    offsets[k] = at;
    at += levels[k].length;
  }
  final out = Uint8List(at);
  final d = ByteData.sublistView(out);
  out.setAll(0, _identifier);
  final fields = [
    format.vk,
    format.typeSize,
    width,
    height,
    depth,
    layers,
    faces,
    levels.length,
    0,
    dfdAt,
    dfd.length,
    kvdAt,
    kvd.length,
  ];
  for (var i = 0; i < fields.length; i++) {
    d.setUint32(12 + 4 * i, fields[i], Endian.little);
  }
  // The file has no supercompression global data. Its offset and length
  // stay zero.
  for (var k = 0; k < levels.length; k++) {
    final e = header + 24 * k;
    d.setUint64(e, offsets[k], Endian.little);
    d.setUint64(e + 8, levels[k].length, Endian.little);
    d.setUint64(e + 16, levels[k].length, Endian.little);
    out.setAll(offsets[k], levels[k]);
  }
  out.setAll(dfdAt, dfd);
  out.setAll(kvdAt, kvd);
  return out;
}

const _identifier = [
  0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb, 0x0d, 0x0a, 0x1a, 0x0a, //
];

int _lcm4(int n) {
  var a = n, b = 4;
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return n * 4 ~/ a;
}

/// The texture formats that [encodeKtx2] writes, with their Vulkan format
/// numbers.
enum Ktx2Format {
  rgba8(37, 1, 4),
  rgba8Srgb(43, 1, 4),
  bgra8(44, 1, 4),
  bgra8Srgb(50, 1, 4),
  r8(9, 1, 1),
  rg8(16, 1, 2),
  a8(1000470001, 1, 1),
  rgba16f(97, 2, 8),
  r32ui(98, 4, 4),
  bc1(133, 1, 8),
  bc1Srgb(134, 1, 8),
  bc3(137, 1, 16),
  bc3Srgb(138, 1, 16);

  const Ktx2Format(this.vk, this.typeSize, this.blockBytes);
  final int vk, typeSize, blockBytes;

  bool get srgb => name.endsWith('Srgb');
  bool get block => vk >= 131 && vk <= 184;
}

/// Returns the basic data format descriptor of Khronos Data Format 1.3 for
/// [f]. It has one sample per channel. A block format has the samples of
/// its colour model.
Uint8List _dfd(Ktx2Format f) {
  // Each sample has a bit offset, a bit length, a channel with qualifiers
  // and a lower and an upper value.
  final List<(int, int, int, int, int)> samples;
  var model = 1, dims = [0, 0, 0, 0];
  const linear = 0x10, float = 0x80, signed = 0x40;
  final alphaFlag = f.srgb ? linear : 0;
  switch (f) {
    case Ktx2Format.rgba8 || Ktx2Format.rgba8Srgb:
      samples = [
        (0, 8, 0, 0, 255),
        (8, 8, 1, 0, 255),
        (16, 8, 2, 0, 255),
        (24, 8, 15 | alphaFlag, 0, 255),
      ];
    case Ktx2Format.bgra8 || Ktx2Format.bgra8Srgb:
      samples = [
        (0, 8, 2, 0, 255),
        (8, 8, 1, 0, 255),
        (16, 8, 0, 0, 255),
        (24, 8, 15 | alphaFlag, 0, 255),
      ];
    case Ktx2Format.r8:
      samples = [(0, 8, 0, 0, 255)];
    case Ktx2Format.rg8:
      samples = [(0, 8, 0, 0, 255), (8, 8, 1, 0, 255)];
    case Ktx2Format.a8:
      samples = [(0, 8, 15, 0, 255)];
    case Ktx2Format.rgba16f:
      const lo = 0xbf800000, hi = 0x3f800000;
      samples = [
        for (var c = 0; c < 4; c++)
          (16 * c, 16, (c == 3 ? 15 : c) | float | signed, lo, hi),
      ];
    case Ktx2Format.r32ui:
      samples = [(0, 32, 0, 0, 0xffffffff)];
    case Ktx2Format.bc1 || Ktx2Format.bc1Srgb:
      model = 128;
      dims = [3, 3, 0, 0];
      // BC1 with punch-through alpha. Its one sample marks alpha as present.
      samples = [(0, 64, 1, 0, 0xffffffff)];
    case Ktx2Format.bc3 || Ktx2Format.bc3Srgb:
      model = 130;
      dims = [3, 3, 0, 0];
      samples = [
        (0, 64, 15 | alphaFlag, 0, 0xffffffff),
        (64, 64, 0, 0, 0xffffffff),
      ];
  }
  final block = 24 + 16 * samples.length;
  final out = Uint8List(4 + block);
  final d = ByteData.sublistView(out);
  d.setUint32(0, out.length, Endian.little);
  d.setUint32(4, 0, Endian.little); // Khronos, basic descriptor
  d.setUint16(8, 2, Endian.little); // version 1.3
  d.setUint16(10, block, Endian.little);
  out[12] = model;
  out[13] = 1; // BT.709 primaries
  out[14] = f.srgb ? 2 : 1; // sRGB or linear transfer
  out[15] = 0; // straight alpha
  out.setAll(16, dims);
  out[20] = f.blockBytes; // bytes in plane 0
  for (var i = 0; i < samples.length; i++) {
    final (offset, length, channel, lower, upper) = samples[i];
    final s = 28 + 16 * i;
    d.setUint16(s, offset, Endian.little);
    out[s + 2] = length - 1;
    out[s + 3] = channel;
    d.setUint32(s + 8, lower, Endian.little);
    d.setUint32(s + 12, upper, Endian.little);
  }
  return out;
}

/// Returns the key-value data of [values]. Each pair has its length, then
/// the key and the value, each ended by NUL, padded to 4 bytes. The keys are
/// in byte order, as the spec asks.
Uint8List _kvd(Map<String, String> values) {
  final b = BytesBuilder();
  for (final k in values.keys.toList()..sort()) {
    final pair = [...utf8.encode(k), 0, ...utf8.encode(values[k]!), 0];
    b.add(
      Uint8List(4)
        ..buffer.asByteData().setUint32(0, pair.length, Endian.little),
    );
    b.add(pair);
    while (b.length % 4 != 0) {
      b.addByte(0);
    }
  }
  return b.toBytes();
}

/// A KTX2 file as read: its format, size, layers and mip levels.
class Ktx2Image {
  Ktx2Image(
    this.format,
    this.width,
    this.height,
    this.layers,
    this.faces,
    this.levels,
  );

  final Ktx2Format format;
  final int width, height, layers, faces;

  /// Each mip level, largest first, as stored.
  final List<Uint8List> levels;
}

/// Reads a KTX2 file without supercompression in one of the formats of
/// [Ktx2Format]. The levels are views into [bytes].
Ktx2Image readKtx2(Uint8List bytes) {
  for (var i = 0; i < _identifier.length; i++) {
    if (bytes.length < 80 || bytes[i] != _identifier[i]) {
      throw const FormatException('not a KTX2 file');
    }
  }
  final d = ByteData.sublistView(bytes);
  int u32(int at) => d.getUint32(at, Endian.little);
  final vk = u32(12);
  final format = Ktx2Format.values.firstWhere(
    (f) => f.vk == vk,
    orElse: () => throw FormatException('KTX2 format $vk is not supported'),
  );
  if (u32(44) != 0) {
    throw const FormatException('KTX2 supercompression is not supported');
  }
  final count = u32(40) == 0 ? 1 : u32(40);
  return Ktx2Image(format, u32(20), u32(24), u32(32), u32(36), [
    for (var k = 0; k < count; k++)
      Uint8List.sublistView(
        bytes,
        d.getUint64(80 + 24 * k, Endian.little),
        d.getUint64(80 + 24 * k, Endian.little) +
            d.getUint64(88 + 24 * k, Endian.little),
      ),
  ]);
}
