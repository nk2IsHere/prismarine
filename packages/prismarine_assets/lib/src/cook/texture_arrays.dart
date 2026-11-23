import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';

import '../image/ktx2.dart';

/// A texture's group key: textures share an array only when every level's
/// image has the same size and format, so a layer is the file's own bytes.
typedef TextureGroup = ({int width, int height, int vk, int levels});

/// [stem]'s group from its KTX2 header, or null when it isn't a plain 2D
/// texture (arrays, cubes and volumes stay as they are).
TextureGroup? textureGroup(String slice, String stem) {
  final f = File('$slice/textures/$stem.ktx2');
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

/// Writes one KTX2 array per group of [stems] into `[outDir]/textures/`
/// (named by the group, so the same group in two scenes is two files) and
/// returns them
/// in a stable order: groups by size then format, layers by stem. The
/// key-value data of each array holds its layer stems under [layersKey].
List<CookedArray> cookTextureArrays(
  String slice,
  Iterable<String> stems,
  String outDir, {
  required String layersKey,
}) {
  final groups = <TextureGroup, List<String>>{};
  for (final s in stems) {
    final g = textureGroup(slice, s);
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
      orElse: () => throw StateError('no KTX2 format for vkFormat ${g.vk}'),
    );
    final files = [
      for (final s in layers) File('$slice/textures/$s.ktx2').readAsBytesSync(),
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
    // `textures/<stem>.ktx2`, as a slice keeps its textures, so the
    // renderer's texture loader reads an array as it reads any texture.
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

/// The image of [level] in a KTX2 [file] of one layer and one face.
Uint8List _level(Uint8List file, int level) {
  final d = ByteData.sublistView(file);
  final at = d.getUint64(80 + 24 * level, Endian.little);
  final length = d.getUint64(80 + 24 * level + 8, Endian.little);
  return Uint8List.sublistView(file, at, at + length);
}
