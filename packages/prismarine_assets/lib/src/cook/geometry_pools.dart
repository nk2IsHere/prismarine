import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';

import '../gltf/gltf_builder.dart';

const _components = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4};
const _counts = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16};

/// One attribute stream of a pool. It has the shape of a glTF accessor and
/// the tightly packed bytes of every vertex added so far.
class _Stream {
  _Stream(this.componentType, this.type, this.normalized);
  final int componentType;
  final String type;
  final bool normalized;
  final bytes = BytesBuilder(copy: false);
  int get elementSize => _components[componentType]! * _counts[type]!;
}

class _Pool {
  _Pool(this.layout);
  final String layout;
  final streams = <String, _Stream>{};
  final indices = BytesBuilder(copy: false);
  int vertexCount = 0, indexCount = 0;
}

/// The vertices and indices of meshes, concatenated into one pool per
/// vertex layout. A pool has one stream per attribute and one 32-bit index
/// buffer. Pools are numbered in the order of their first mesh. The pool
/// GLBs carry [generator] as their `asset.generator`.
class GeometryPools {
  GeometryPools({this.generator = 'prismarine_assets'});

  final String generator;
  final _pools = <_Pool>[];
  final _byLayout = <String, int>{};

  /// Adds the vertices of one mesh of a GLB with the chunks [json] and
  /// [bin]. [attributes] maps each stream name to the accessor of its data
  /// and must hold `POSITION`. The sorted stream names and their accessor
  /// shapes give the layout. Returns the pool of the layout and the first
  /// vertex of the mesh in it.
  ({int pool, int baseVertex}) addVertices(
    Map<String, Object?> json,
    Uint8List bin,
    Map<String, int> attributes,
  ) {
    final acc = (json['accessors']! as List).cast<Map<String, Object?>>();
    final views = (json['bufferViews']! as List).cast<Map<String, Object?>>();
    final names = attributes.keys.toList()..sort();
    String shape(int i) {
      final a = acc[i];
      return '${a['componentType']}:${a['type']}'
          '${a['normalized'] == true ? ':n' : ''}';
    }

    final layout = [
      for (final n in names) '$n:${shape(attributes[n]!)}',
    ].join('|');
    final index = _byLayout.putIfAbsent(layout, () {
      _pools.add(_Pool(layout));
      return _pools.length - 1;
    });
    final pool = _pools[index];
    final baseVertex = pool.vertexCount;
    final vertexCount = acc[attributes['POSITION']!]['count']! as int;
    for (final n in names) {
      final a = acc[attributes[n]!];
      final s = pool.streams.putIfAbsent(
        n,
        () => _Stream(
          a['componentType']! as int,
          a['type']! as String,
          a['normalized'] == true,
        ),
      );
      s.bytes.add(_packed(bin, a, views, s.elementSize));
    }
    pool.vertexCount += vertexCount;
    return (pool: index, baseVertex: baseVertex);
  }

  /// Appends the indices of [accessor] of a GLB with the chunks [json] and
  /// [bin] to [pool]. The indices stay relative to the first vertex of
  /// their mesh. Returns their range in the index buffer of the pool.
  ({int firstIndex, int indexCount}) addIndices(
    int pool,
    Map<String, Object?> json,
    Uint8List bin,
    int accessor,
  ) {
    final acc = (json['accessors']! as List).cast<Map<String, Object?>>();
    final views = (json['bufferViews']! as List).cast<Map<String, Object?>>();
    final p = _pools[pool];
    final idx = _indices(bin, acc[accessor], views);
    final firstIndex = p.indexCount;
    p.indices.add(idx.buffer.asUint8List());
    p.indexCount += idx.length;
    return (firstIndex: firstIndex, indexCount: idx.length);
  }

  /// Writes pool i as `pool_<i>.glb` into [outDir]. Returns the pools in
  /// their order.
  List<CookedPool> write(String outDir) {
    final cooked = <CookedPool>[];
    for (var i = 0; i < _pools.length; i++) {
      final p = _pools[i];
      final file = 'pool_$i.glb';
      File('$outDir/$file').writeAsBytesSync(_poolGlb(p, generator));
      cooked.add(
        CookedPool(
          file: file,
          layout: p.layout,
          vertexCount: p.vertexCount,
          indexCount: p.indexCount,
        ),
      );
    }
    return cooked;
  }
}

/// Returns the elements of accessor [a] tightly packed. The elements of a
/// strided view are de-interleaved.
Uint8List _packed(
  Uint8List bin,
  Map<String, Object?> a,
  List<Map<String, Object?>> views,
  int size,
) {
  final v = views[a['bufferView']! as int];
  final count = a['count']! as int;
  final start =
      ((v['byteOffset'] as int?) ?? 0) + ((a['byteOffset'] as int?) ?? 0);
  final stride = (v['byteStride'] as int?) ?? size;
  if (stride == size) {
    return Uint8List.sublistView(bin, start, start + size * count);
  }
  final out = Uint8List(size * count);
  for (var e = 0; e < count; e++) {
    out.setRange(e * size, e * size + size, bin, start + e * stride);
  }
  return out;
}

/// Returns the indices of accessor [a] as 32-bit values.
Uint32List _indices(
  Uint8List bin,
  Map<String, Object?> a,
  List<Map<String, Object?>> views,
) {
  final v = views[a['bufferView']! as int];
  final count = a['count']! as int;
  final start =
      ((v['byteOffset'] as int?) ?? 0) + ((a['byteOffset'] as int?) ?? 0);
  final d = ByteData.sublistView(bin);
  final out = Uint32List(count);
  final type = a['componentType']! as int;
  for (var i = 0; i < count; i++) {
    out[i] = switch (type) {
      5121 => d.getUint8(start + i),
      5123 => d.getUint16(start + 2 * i, Endian.little),
      _ => d.getUint32(start + 4 * i, Endian.little),
    };
  }
  return out;
}

/// Returns pool [p] as a GLB that a glTF viewer opens. Each stream is an
/// accessor over all vertices, with one uint32 index accessor and one
/// primitive over all indices. The indices are relative to their mesh. A
/// viewer therefore shows a distorted picture.
Uint8List _poolGlb(_Pool p, String generator) {
  final b = GltfBuilder(generator: generator);
  final attributes = <String, int>{};
  for (final MapEntry(key: name, value: s) in p.streams.entries) {
    final view = b.addView(s.bytes.toBytes(), target: 34962);
    attributes[name] = b.addAccessor({
      'bufferView': view,
      'componentType': s.componentType,
      'type': s.type,
      'count': p.vertexCount,
      if (s.normalized) 'normalized': true,
    });
  }
  final iv = b.addView(p.indices.toBytes(), target: 34963);
  final indices = b.addAccessor({
    'bufferView': iv,
    'componentType': 5125,
    'type': 'SCALAR',
    'count': p.indexCount,
  });
  b.json['meshes'] = [
    {
      'name': p.layout,
      'primitives': [
        {'attributes': attributes, 'indices': indices},
      ],
    },
  ];
  return b.toGlb();
}
