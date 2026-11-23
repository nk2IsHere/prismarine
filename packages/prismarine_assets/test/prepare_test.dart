import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:test/test.dart';

/// A grid of [n] by [n] quads in the XZ plane with UVs and 32-bit indices,
/// written as a glTF with one PNG texture.
String _gridGltf(Directory dir, int n) {
  final verts = (n + 1) * (n + 1);
  final pos = Float32List(verts * 3), uv = Float32List(verts * 2);
  for (var z = 0; z <= n; z++) {
    for (var x = 0; x <= n; x++) {
      final v = z * (n + 1) + x;
      pos
        ..[v * 3] = x.toDouble()
        ..[v * 3 + 2] = z.toDouble();
      uv
        ..[v * 2] = x / n
        ..[v * 2 + 1] = z / n;
    }
  }
  final idx = Uint32List(n * n * 6);
  var k = 0;
  for (var z = 0; z < n; z++) {
    for (var x = 0; x < n; x++) {
      final a = z * (n + 1) + x, b = a + 1, c = a + n + 1, d = c + 1;
      idx.setAll(k, [a, c, b, b, c, d]);
      k += 6;
    }
  }
  final bin = BytesBuilder()
    ..add(pos.buffer.asUint8List())
    ..add(uv.buffer.asUint8List())
    ..add(idx.buffer.asUint8List());
  File('${dir.path}/grid.bin').writeAsBytesSync(bin.toBytes());
  final png = Uint8List(8 * 8 * 4);
  for (var i = 0; i < 64; i++) {
    png.setAll(i * 4, [200, 100, 50, i < 32 ? 255 : 0]);
  }
  File('${dir.path}/base.png').writeAsBytesSync(encodePng(8, 8, png));
  final json = {
    'asset': {'version': '2.0'},
    'buffers': [
      {'uri': 'grid.bin', 'byteLength': bin.length},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': pos.lengthInBytes},
      {
        'buffer': 0,
        'byteOffset': pos.lengthInBytes,
        'byteLength': uv.lengthInBytes,
      },
      {
        'buffer': 0,
        'byteOffset': pos.lengthInBytes + uv.lengthInBytes,
        'byteLength': idx.lengthInBytes,
      },
    ],
    'accessors': [
      {'bufferView': 0, 'componentType': 5126, 'count': verts, 'type': 'VEC3'},
      {'bufferView': 1, 'componentType': 5126, 'count': verts, 'type': 'VEC2'},
      {
        'bufferView': 2,
        'componentType': 5125,
        'count': idx.length,
        'type': 'SCALAR',
      },
    ],
    'images': [
      {'uri': 'base.png'},
    ],
    'textures': [
      {'source': 0},
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorTexture': {'index': 0},
        },
        'alphaMode': 'MASK',
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'TEXCOORD_0': 1},
            'indices': 2,
            'material': 0,
          },
        ],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'scene': 0,
  };
  final path = '${dir.path}/grid.gltf';
  File(path).writeAsStringSync(jsonEncode(json));
  return path;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('prepare_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('splitChunks keeps every triangle under the vertex limit', () {
    final idx = Uint32List.fromList([for (var i = 0; i < 300; i++) i]);
    final chunks = splitChunks(idx, 300, maxVertices: 64);
    expect(chunks.every((c) => c.vertices.length <= 64), isTrue);
    final back = [
      for (final c in chunks)
        for (final i in c.indices) c.vertices[i],
    ];
    expect(back, idx);
  });

  test('vertexTangents follow the U direction of the UVs', () {
    final pos = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 0, 1]);
    final nrm = Float32List.fromList([0, 1, 0, 0, 1, 0, 0, 1, 0]);
    final uv = Float32List.fromList([0, 0, 1, 0, 0, 1]);
    final t = vertexTangents(pos, nrm, uv, Uint32List.fromList([0, 2, 1]));
    expect(t.sublist(0, 3), [1, 0, 0]);
    expect(t[3].abs(), 1);
  });

  test('readKtx2 reads what encodeKtx2 wrote', () {
    final (w, h, levels) = mipChainRgba8(
      Uint8List.fromList(List.filled(16 * 8 * 4, 128)),
      16,
      8,
      TextureUse.color,
      maxSize: 8,
    );
    expect((w, h), (8, 4));
    final k = readKtx2(
      encodeKtx2(
        format: Ktx2Format.rgba8Srgb,
        width: w,
        height: h,
        levels: levels,
      ),
    );
    expect(k.format, Ktx2Format.rgba8Srgb);
    expect((k.width, k.height, k.levels.length), (8, 4, 4));
    expect(k.levels.last, levels.last);
  });

  test('normal mips stay unit length', () {
    final n = Uint8List.fromList([255, 128, 128, 255, 128, 255, 128, 255]);
    final half = halveRgba8(n, 2, 1, TextureUse.normal);
    final x = half[0] / 127.5 - 1, y = half[1] / 127.5 - 1;
    final z = half[2] / 127.5 - 1;
    expect(math.sqrt(x * x + y * y + z * z), closeTo(1, 0.02));
  });

  test(
    'prepareGltf splits a large primitive and converts its texture',
    () async {
      // 300 by 300 quads have 90,601 vertices and 180,000 triangles.
      final src = _gridGltf(dir, 300);
      final out = '${dir.path}/out';
      final r = await prepareGltf(src, out, jobs: 1, textureSize: 4);
      expect(r.primitives, 1);
      final doc = GltfDocument.open('$out/scene.gltf');
      final prims = doc.list('meshes').single['primitives'] as List;
      expect(prims.length, r.chunks);
      var triangles = 0;
      for (final p in prims.cast<Map<String, Object?>>()) {
        final a = (p['attributes'] as Map).cast<String, int>();
        expect(a.keys, containsAll(['POSITION', 'NORMAL', 'TANGENT']));
        expect(doc.count(a['POSITION']!), lessThanOrEqualTo(65535));
        expect(doc.accessor(p['indices'] as int)['componentType'], 5123);
        triangles += doc.count(p['indices'] as int) ~/ 3;
        final normals = doc.floats(a['NORMAL']!);
        expect(normals[1].abs(), closeTo(1, 1e-5));
      }
      expect(triangles, 180000);
      expect(r.chunks, greaterThan(1));
      final k = readKtx2(File('$out/textures/0.ktx2').readAsBytesSync());
      expect(
        (k.format, k.width, k.levels.length),
        (Ktx2Format.rgba8Srgb, 4, 3),
      );
      expect(doc.list('images').single['uri'], 'textures/0.ktx2');
    },
  );
}
