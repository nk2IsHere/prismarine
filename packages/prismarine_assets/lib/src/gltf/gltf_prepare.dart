import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'gltf_document.dart';
import 'gltf_geometry.dart';
import 'gltf_prepare_textures.dart';

/// What [prepareGltf] made.
class PrepareReport {
  PrepareReport(this.primitives, this.chunks, this.textures, this.skipped);
  final int primitives, chunks, textures;

  /// One line for each part that the output leaves out, such as a primitive
  /// of lines.
  final List<String> skipped;
}

/// Writes the glTF at [source] as a glTF that the GPU loads without work
/// into [outDir]: `scene.gltf`, `scene.bin` and `textures/<n>.ktx2`.
///
/// Each triangle primitive becomes one or more primitives with 16-bit
/// indices and at most 65,535 vertices. Each has one interleaved buffer
/// view of [preparedStride] bytes per vertex with `POSITION`, `NORMAL`,
/// `TANGENT` and `TEXCOORD_0`. Missing normals and tangents are computed.
/// Each texture becomes RGBA8 KTX2 with every mip level, no side larger
/// than [textureSize]. Base colour and emissive textures are sRGB. [jobs]
/// textures are converted at a time. A texture whose KTX2 file is newer
/// than its source is kept. [log] receives one line per step.
Future<PrepareReport> prepareGltf(
  String source,
  String outDir, {
  int textureSize = 1024,
  int jobs = 4,
  void Function(String line)? log,
}) async {
  final doc = GltfDocument.open(source);
  final json = doc.json;
  Directory('$outDir/textures').createSync(recursive: true);
  final bin = File('$outDir/scene.bin').openSync(mode: FileMode.write);
  var binLength = 0;
  final views = <Map<String, Object?>>[];
  final accessors = <Map<String, Object?>>[];
  final skipped = <String>[];
  int addView(Uint8List bytes, int target, {int? stride}) {
    final pad = (4 - binLength % 4) % 4;
    if (pad > 0) bin.writeFromSync(Uint8List(pad));
    binLength += pad;
    views.add({
      'buffer': 0,
      'byteOffset': binLength,
      'byteLength': bytes.length,
      'byteStride': ?stride,
      'target': target,
    });
    bin.writeFromSync(bytes);
    binLength += bytes.length;
    return views.length - 1;
  }

  var primitives = 0, chunkCount = 0;
  final meshes = <Map<String, Object?>>[];
  for (final (m, mesh) in doc.list('meshes').indexed) {
    final out = <Map<String, Object?>>[];
    for (final (p, prim) in (mesh['primitives'] as List).indexed) {
      final prim0 = prim as Map<String, Object?>;
      final mode = (prim0['mode'] as int?) ?? 4;
      if (mode != 4) {
        skipped.add('mesh $m primitive $p: mode $mode is not triangles');
        continue;
      }
      primitives++;
      for (final c in _chunks(doc, prim0)) {
        final (vertices, lo, hi) = c.vertexBytes;
        final vv = addView(vertices, 34962, stride: preparedStride);
        final first = accessors.length;
        accessors
          ..add({
            'bufferView': vv,
            'byteOffset': 0,
            'componentType': 5126,
            'count': c.chunk.vertices.length,
            'type': 'VEC3',
            'min': lo,
            'max': hi,
          })
          ..add(_attribute(vv, 12, c.chunk.vertices.length, 'VEC3'))
          ..add(_attribute(vv, 24, c.chunk.vertices.length, 'VEC4'))
          ..add(_attribute(vv, 40, c.chunk.vertices.length, 'VEC2'));
        final iv = addView(c.chunk.indices.buffer.asUint8List(), 34963);
        accessors.add({
          'bufferView': iv,
          'componentType': 5123,
          'count': c.chunk.indices.length,
          'type': 'SCALAR',
        });
        out.add({
          'attributes': {
            'POSITION': first,
            'NORMAL': first + 1,
            'TANGENT': first + 2,
            'TEXCOORD_0': first + 3,
          },
          'indices': first + 4,
          'material': ?prim0['material'],
        });
        chunkCount++;
      }
    }
    meshes.add({'name': ?mesh['name'], 'primitives': out});
  }
  bin.closeSync();
  log?.call('geometry: $primitives primitives in $chunkCount chunks');

  final textures = await prepareTextures(
    doc,
    outDir,
    textureSize: textureSize,
    jobs: jobs,
    log: log,
  );
  final keep = Map<String, Object?>.of(json)
    ..remove('extensionsRequired')
    ..remove('animations')
    ..remove('skins');
  keep['asset'] = {
    'version': '2.0',
    'generator': 'prismarine_assets prepareGltf',
    'copyright': ?(json['asset'] as Map?)?['copyright'],
  };
  keep['buffers'] = [
    {'uri': 'scene.bin', 'byteLength': binLength},
  ];
  keep['bufferViews'] = views;
  keep['accessors'] = accessors;
  keep['meshes'] = meshes;
  keep['images'] = textures.images;
  keep['textures'] = textures.textures;
  // Lights and cameras stay. Other extensions may name parts that changed.
  final used = (json['extensionsUsed'] as List?)?.where(
    (e) => e == 'KHR_lights_punctual' || e == 'KHR_materials_emissive_strength',
  );
  keep['extensionsUsed'] = used == null || used.isEmpty ? null : used.toList();
  keep.removeWhere((_, v) => v == null || (v is List && v.isEmpty));
  File(
    '$outDir/scene.gltf',
  ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(keep));
  return PrepareReport(primitives, chunkCount, textures.count, skipped);
}

Map<String, Object?> _attribute(int view, int offset, int count, String type) =>
    {
      'bufferView': view,
      'byteOffset': offset,
      'componentType': 5126,
      'count': count,
      'type': type,
    };

class _Chunk {
  _Chunk(this.chunk, this.vertexBytes);
  final GeometryChunk chunk;
  final (Uint8List, List<double>, List<double>) vertexBytes;
}

/// The chunks of a triangle primitive with its streams made complete.
Iterable<_Chunk> _chunks(GltfDocument doc, Map<String, Object?> prim) sync* {
  final attrs = (prim['attributes'] as Map).cast<String, int>();
  final positions = doc.floats(attrs['POSITION']!);
  final count = positions.length ~/ 3;
  final idx = prim['indices'] as int?;
  final indices = idx == null
      ? Uint32List.fromList([for (var i = 0; i < count; i++) i])
      : doc.uints(idx);
  final normals = attrs['NORMAL'] != null
      ? doc.floats(attrs['NORMAL']!)
      : vertexNormals(positions, indices);
  final uvs = attrs['TEXCOORD_0'] != null
      ? doc.floats(attrs['TEXCOORD_0']!)
      : Float32List(count * 2);
  final tangents = attrs['TANGENT'] != null
      ? doc.floats(attrs['TANGENT']!)
      : vertexTangents(positions, normals, uvs, indices);
  for (final c in splitChunks(indices, count)) {
    yield _Chunk(c, interleave(c, positions, normals, tangents, uvs));
  }
}
