import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'gltf_builder.dart' show readGlb;

/// A glTF 2.0 file as read, its JSON and its buffers, with the reads of its
/// accessors. A `.gltf` file reads its buffers from files beside it or from
/// data URIs. A `.glb` file has its first buffer in its binary chunk.
class GltfDocument {
  GltfDocument(this.json, this.buffers, {this.dir = '.'});

  /// Reads the `.gltf` or `.glb` file at [path] with its buffers.
  factory GltfDocument.open(String path) {
    final file = File(path);
    final dir = file.parent.path;
    final bytes = file.readAsBytesSync();
    if (bytes.length >= 4 &&
        ByteData.sublistView(bytes).getUint32(0, Endian.little) == 0x46546C67) {
      final glb = readGlb(bytes);
      return GltfDocument(glb.json, _buffers(glb.json, dir, glb.bin), dir: dir);
    }
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return GltfDocument(json, _buffers(json, dir, null), dir: dir);
  }

  final Map<String, Object?> json;
  final List<Uint8List> buffers;

  /// The directory that relative URIs start from.
  final String dir;

  static List<Uint8List> _buffers(
    Map<String, Object?> json,
    String dir,
    Uint8List? bin,
  ) => [
    for (final (i, b) in _maps(json['buffers']).indexed)
      switch (b['uri']) {
        null when i == 0 && bin != null => bin,
        final String uri => readUri(uri, dir),
        _ => throw FormatException('buffer $i has no data'),
      },
  ];

  /// Reads [uri], a data URI or a path relative to [dir].
  static Uint8List readUri(String uri, String dir) {
    if (uri.startsWith('data:')) {
      return Uint8List.fromList(UriData.parse(uri).contentAsBytes());
    }
    return File('$dir/${Uri.decodeComponent(uri)}').readAsBytesSync();
  }

  static List<Map<String, Object?>> _maps(Object? l) =>
      ((l as List?) ?? const []).cast<Map<String, Object?>>();

  /// The entries of the top-level array [key], such as `meshes`.
  List<Map<String, Object?>> list(String key) => _maps(json[key]);

  Map<String, Object?> accessor(int i) => list('accessors')[i];

  /// The number of elements of accessor [i].
  int count(int i) => accessor(i)['count'] as int;

  /// The components per element of accessor [i], 3 for a `VEC3`.
  int components(int i) => _components[accessor(i)['type']]!;

  static const _components = {
    'SCALAR': 1,
    'VEC2': 2,
    'VEC3': 3,
    'VEC4': 4,
    'MAT2': 4,
    'MAT3': 9,
    'MAT4': 16,
  };

  /// Reads accessor [i] as floats, element after element. Normalized
  /// integers become values from 0 to 1, or from -1 to 1 when signed. An
  /// accessor without a buffer view reads as zeros. The elements of a
  /// sparse accessor replace those at its indices.
  Float32List floats(int i) {
    final a = accessor(i);
    final n = count(i), c = components(i);
    final out = Float32List(n * c);
    final type = a['componentType'] as int;
    final norm = a['normalized'] == true;
    final size = _size(type);
    if (a['bufferView'] case final int view) {
      final (data, stride) = _element(i, view, type, c);
      for (var e = 0; e < n; e++) {
        for (var k = 0; k < c; k++) {
          out[e * c + k] = _float(data, e * stride + k * size, type, norm, i);
        }
      }
    }
    if (a['sparse'] case final Map sparse) {
      final (indices, values) = _sparse(sparse);
      for (var j = 0; j < indices.length; j++) {
        for (var k = 0; k < c; k++) {
          out[indices[j] * c + k] = _float(
            values,
            (j * c + k) * size,
            type,
            norm,
            i,
          );
        }
      }
    }
    return out;
  }

  static double _float(ByteData data, int at, int type, bool norm, int i) =>
      switch (type) {
        5126 => data.getFloat32(at, Endian.little),
        5120 => norm ? _max(data.getInt8(at) / 127) : data.getInt8(at) * 1.0,
        5121 => norm ? data.getUint8(at) / 255 : data.getUint8(at) * 1.0,
        5122 =>
          norm
              ? _max(data.getInt16(at, Endian.little) / 32767)
              : data.getInt16(at, Endian.little) * 1.0,
        5123 =>
          norm
              ? data.getUint16(at, Endian.little) / 65535
              : data.getUint16(at, Endian.little) * 1.0,
        5125 => data.getUint32(at, Endian.little) * 1.0,
        _ => throw FormatException('accessor $i has component type $type'),
      };

  /// The indices of [sparse] and the bytes of its values.
  (List<int>, ByteData) _sparse(Map sparse) {
    final n = sparse['count'] as int;
    final ix = sparse['indices'] as Map, vx = sparse['values'] as Map;
    ByteData bytes(Map m) {
      final v = list('bufferViews')[m['bufferView'] as int];
      return ByteData.sublistView(
        buffers[v['buffer'] as int],
        ((v['byteOffset'] as int?) ?? 0) + ((m['byteOffset'] as int?) ?? 0),
      );
    }

    final type = ix['componentType'] as int;
    final at = bytes(ix);
    final indices = [
      for (var j = 0; j < n; j++)
        switch (type) {
          5121 => at.getUint8(j),
          5123 => at.getUint16(2 * j, Endian.little),
          _ => at.getUint32(4 * j, Endian.little),
        },
    ];
    return (indices, bytes(vx));
  }

  static double _max(double v) => v < -1 ? -1 : v;

  /// Reads accessor [i] of unsigned integers as 32-bit values, such as the
  /// indices of a primitive. The elements of a sparse accessor replace those
  /// at its indices.
  Uint32List uints(int i) {
    final a = accessor(i);
    final n = count(i), c = components(i);
    final out = Uint32List(n * c);
    final type = a['componentType'] as int;
    final size = _size(type);
    int read(ByteData data, int at) => switch (type) {
      5121 => data.getUint8(at),
      5123 => data.getUint16(at, Endian.little),
      5125 => data.getUint32(at, Endian.little),
      _ => throw FormatException('accessor $i is not unsigned'),
    };
    if (a['bufferView'] case final int view) {
      final (data, stride) = _element(i, view, type, c);
      for (var e = 0; e < n; e++) {
        for (var k = 0; k < c; k++) {
          out[e * c + k] = read(data, e * stride + k * size);
        }
      }
    }
    if (a['sparse'] case final Map sparse) {
      final (indices, values) = _sparse(sparse);
      for (var j = 0; j < indices.length; j++) {
        for (var k = 0; k < c; k++) {
          out[indices[j] * c + k] = read(values, (j * c + k) * size);
        }
      }
    }
    return out;
  }

  /// The bytes of accessor [i] from its first element, and its stride.
  (ByteData, int) _element(int i, int view, int type, int c) {
    final v = list('bufferViews')[view];
    final buffer = buffers[v['buffer'] as int];
    final start =
        ((v['byteOffset'] as int?) ?? 0) +
        ((accessor(i)['byteOffset'] as int?) ?? 0);
    final stride = (v['byteStride'] as int?) ?? _size(type) * c;
    return (ByteData.sublistView(buffer, start), stride);
  }

  static int _size(int type) => switch (type) {
    5120 || 5121 => 1,
    5122 || 5123 => 2,
    _ => 4,
  };
}
