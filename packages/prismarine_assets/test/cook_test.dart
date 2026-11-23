import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:test/test.dart';

import 'ktx2_test.dart' show keyValues;

/// A one-mesh GLB of [positions] (x, y, z per vertex) with two index lists
/// over them, the positions in a strided view when [interleaved].
({Map<String, Object?> json, Uint8List bin}) _mesh(
  List<double> positions, {
  bool interleaved = false,
}) {
  final b = GltfBuilder();
  final n = positions.length ~/ 3;
  if (interleaved) {
    // Each position is followed by one padding float, a stride of 16.
    final data = Float32List(n * 4);
    for (var v = 0; v < n; v++) {
      data.setRange(v * 4, v * 4 + 3, positions, v * 3);
    }
    final view = b.addView(data.buffer.asUint8List(), stride: 16);
    b.addAccessor({
      'bufferView': view,
      'componentType': 5126,
      'type': 'VEC3',
      'count': n,
    });
  } else {
    b.addFloatAccessor(Float32List.fromList(positions), 'VEC3');
  }
  b
    ..addIndexAccessor(Uint16List.fromList([0, 1, 2]))
    ..addIndexAccessor(Uint16List.fromList([2, 1, 0]));
  return readGlb(b.toGlb());
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cook'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('meshes of one layout share a pool at their own base vertex', () {
    final pools = GeometryPools(generator: 'test');
    final a = _mesh([0, 0, 0, 1, 0, 0, 0, 1, 0]);
    final b = _mesh([5, 5, 5, 6, 5, 5, 5, 6, 5, 9, 9, 9], interleaved: true);
    final pa = pools.addVertices(a.json, a.bin, {'POSITION': 0});
    final ia = pools.addIndices(pa.pool, a.json, a.bin, 1);
    final pb = pools.addVertices(b.json, b.bin, {'POSITION': 0});
    final ib0 = pools.addIndices(pb.pool, b.json, b.bin, 1);
    final ib1 = pools.addIndices(pb.pool, b.json, b.bin, 2);
    expect([pa.pool, pa.baseVertex, pb.pool, pb.baseVertex], [0, 0, 0, 3]);
    expect([ia.firstIndex, ia.indexCount], [0, 3]);
    expect([ib0.firstIndex, ib1.firstIndex], [3, 6]);

    final cooked = pools.write(dir.path).single;
    expect(cooked.file, 'pool_0.glb');
    expect(cooked.layout, 'POSITION:5126:VEC3');
    expect([cooked.vertexCount, cooked.indexCount], [7, 9]);
    final pool = readGlb(File('${dir.path}/pool_0.glb').readAsBytesSync());
    expect((pool.json['asset']! as Map)['generator'], 'test');
    // The second vertex of b is vertex 4 of the pool, de-interleaved.
    final xs = Float32List.sublistView(pool.bin, 0, 7 * 12);
    expect(xs.sublist(12, 15), [6, 5, 5]);
    final indices = Uint32List.sublistView(pool.bin, 7 * 12, 7 * 12 + 36);
    expect(indices, [0, 1, 2, 0, 1, 2, 2, 1, 0]);
  });

  test('another layout gets a pool of its own', () {
    final pools = GeometryPools();
    final a = _mesh([0, 0, 0, 1, 0, 0, 0, 1, 0]);
    pools.addVertices(a.json, a.bin, {'POSITION': 0});
    final other = pools.addVertices(a.json, a.bin, {
      'POSITION': 0,
      'NORMAL': 0,
    });
    expect([other.pool, other.baseVertex], [1, 0]);
    final cooked = pools.write(dir.path);
    expect(cooked.map((p) => p.layout), [
      'POSITION:5126:VEC3',
      'NORMAL:5126:VEC3|POSITION:5126:VEC3',
    ]);
    final glb = readGlb(File('${dir.path}/pool_1.glb').readAsBytesSync());
    expect((glb.json['asset']! as Map)['generator'], 'prismarine_assets');
  });

  test('textures of one size and format share an array, layers by stem', () {
    Directory('${dir.path}/textures').createSync();
    void texture(String stem, int size, int fill, {int layers = 0}) {
      final level = Uint8List(size * size * 4)
        ..fillRange(0, size * size * 4, fill);
      File('${dir.path}/textures/$stem.ktx2').writeAsBytesSync(
        encodeKtx2(
          format: Ktx2Format.rgba8,
          width: size,
          height: size,
          layers: layers,
          levels: [level, Uint8List(4)..fillRange(0, 4, fill + 1)],
        ),
      );
    }

    texture('b', 2, 10);
    texture('a', 2, 20);
    texture('c', 4, 30);
    texture('d', 2, 40, layers: 2);
    expect(textureGroup(dir.path, 'd'), isNull);
    expect(textureGroup(dir.path, 'missing'), isNull);

    final arrays = cookTextureArrays(
      dir.path,
      ['b', 'a', 'c', 'd'],
      '${dir.path}/out',
      layersKey: 'layers',
    );
    expect(arrays.map((a) => a.file), ['array_2x2_37_2', 'array_4x4_37_2']);
    expect(arrays.first.layers, ['a', 'b']);
    final ktx = File(
      '${dir.path}/out/textures/array_2x2_37_2.ktx2',
    ).readAsBytesSync();
    expect(keyValues(ktx)['layers'], 'a,b');
    final d = ByteData.sublistView(ktx);
    expect(d.getUint32(32, Endian.little), 2);
    int levelAt(int k) => d.getUint64(80 + 24 * k, Endian.little);
    expect(ktx.sublist(levelAt(0), levelAt(0) + 32), [
      ...List.filled(16, 20),
      ...List.filled(16, 10),
    ]);
    expect(ktx.sublist(levelAt(1), levelAt(1) + 8), [
      ...List.filled(4, 21),
      ...List.filled(4, 11),
    ]);
  });
}
