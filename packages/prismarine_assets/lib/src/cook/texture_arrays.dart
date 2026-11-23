import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';

import '../image/ktx2.dart';

/// The group of a texture. Textures share an array only when they have the
/// same size, format and number of levels. Each layer then holds the bytes
/// of its texture file unchanged.
typedef TextureGroup = ({int width, int height, int vk, int levels});

/// Returns the group of `[dir]/textures/[stem].ktx2` from its header. Returns
/// null when the file is missing or is not a plain 2D texture, such as an
/// array, a cube or a volume.
TextureGroup? textureGroup(String dir, String stem) {
  final f = File('$dir/textures/$stem.ktx2');
  if (!f.existsSync()) return null;
  final raf = f.openSync();
  try {
    final h = ByteData.sublistView(raf.readSync(48));
    int u32(int at) => h.getUint32(at, Endian.little);
    final (depth, layers, faces) = (u32(28), u32(32), u32(36));
    if (depth > 1 || layers > 1 || faces != 1) return null;
    return (width: u32(20), height: u32(24), vk: u32(12), levels: u32(40));
  } finally {
    raf.closeSync();
  }
}

/// Writes one KTX2 array into `[outDir]/textures/` for each group of the
/// textures `[dir]/textures/<stem>.ktx2` of [stems]. A file has the name of
/// its group. The key-value data of each array holds its layer stems under
/// [layersKey] and its `KTXwriter` holds [writer]. Returns the arrays
/// ordered by size, format and levels, with the layers of each ordered by
/// stem.
List<CookedArray> cookTextureArrays(
  String dir,
  Iterable<String> stems,
  String outDir, {
  required String layersKey,
  String writer = 'prismarine_assets',
}) {
  final groups = <TextureGroup, List<String>>{};
  for (final s in stems) {
    final g = textureGroup(dir, s);
    if (g != null) (groups[g] ??= []).add(s);
  }
  final keys = groups.keys.toList()
    ..sort(
      (a, b) => a.width != b.width
          ? a.width - b.width
          : a.height != b.height
          ? a.height - b.height
          : a.vk != b.vk
          ? a.vk - b.vk
          : a.levels - b.levels,
    );
  final out = <CookedArray>[];
  for (final g in keys) {
    final layers = groups[g]!..sort();
    final format = Ktx2Format.values.firstWhere(
      (f) => f.vk == g.vk,
      orElse: () => throw StateError(
        'The texture arrays have no Ktx2Format for vkFormat ${g.vk}. '
        'Add the format to Ktx2Format.',
      ),
    );
    final files = [
      for (final s in layers) File('$dir/textures/$s.ktx2').readAsBytesSync(),
    ];
    final levels = [
      for (var k = 0; k < g.levels; k++)
        () {
          final b = BytesBuilder(copy: false);
          for (final f in files) {
            b.add(_level(f, k));
          }
          return b.toBytes();
        }(),
    ];
    // The array has the path of a texture, `textures/<stem>.ktx2`. A texture
    // loader reads it as any other texture.
    final name = 'array_${g.width}x${g.height}_${g.vk}_${g.levels}';
    File('$outDir/textures/$name.ktx2')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(
        encodeKtx2(
          format: format,
          width: g.width,
          height: g.height,
          layers: layers.length,
          levels: levels,
          values: {layersKey: layers.join(',')},
          writer: writer,
        ),
      );
    out.add(
      CookedArray(
        file: name,
        width: g.width,
        height: g.height,
        vkFormat: g.vk,
        levels: g.levels,
        layers: layers,
      ),
    );
  }
  return out;
}

/// Returns the image of [level] in a KTX2 [file] of one layer and one face.
Uint8List _level(Uint8List file, int level) {
  final d = ByteData.sublistView(file);
  final at = d.getUint64(80 + 24 * level, Endian.little);
  final length = d.getUint64(80 + 24 * level + 8, Endian.little);
  return Uint8List.sublistView(file, at, at + length);
}
