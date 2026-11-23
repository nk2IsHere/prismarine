import 'dart:convert';
import 'dart:typed_data';

/// Minimal glTF 2.0 builder with one binary buffer, written as GLB.
class GltfBuilder {
  GltfBuilder();

  /// Continues [glb]: its JSON and binary chunk, to add to.
  GltfBuilder.fromGlb(Uint8List glb) {
    final read = readGlb(glb);
    json
      ..clear()
      ..addAll(read.json);
    for (final k in const ['buffers', 'bufferViews', 'accessors']) {
      json[k] ??= <Object?>[];
    }
    _bin.add(read.bin);
  }

  final _bin = BytesBuilder();
  final Map<String, Object?> json = {
    'asset': {'version': '2.0', 'generator': 'mcsm_convert'},
    'buffers': <Object?>[],
    'bufferViews': <Object?>[],
    'accessors': <Object?>[],
  };

  /// A buffer view over [bytes] as given; [stride] for interleaved vertices.
  int addView(Uint8List bytes, {int? target, int? stride}) {
    final v = _view(bytes, target: target);
    if (stride != null) {
      (_list('bufferViews')[v] as Map)['byteStride'] = stride;
    }
    return v;
  }

  /// An accessor as given, over a view from [addView].
  int addAccessor(Map<String, Object?> a) => _accessor(a);

  List<Object?> _list(String k) => (json[k] ??= <Object?>[]) as List<Object?>;

  int _view(Uint8List bytes, {int? target}) {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    final views = _list('bufferViews');
    views.add({
      'buffer': 0,
      'byteOffset': _bin.length,
      'byteLength': bytes.length,
      'target': ?target,
    });
    _bin.add(bytes);
    return views.length - 1;
  }

  int _accessor(Map<String, Object?> a) {
    final l = _list('accessors')..add(a);
    return l.length - 1;
  }

  static const _sizes = {
    'SCALAR': 1,
    'VEC2': 2,
    'VEC3': 3,
    'VEC4': 4,
    'MAT4': 16,
  };

  int addFloatAccessor(
    Float32List data,
    String type, {
    bool minMax = false,
    int? target = 34962,
  }) {
    final n = _sizes[type]!;
    final view = _view(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      target: target,
    );
    List<num>? mn, mx;
    if (minMax && data.isNotEmpty) {
      mn = List<num>.filled(n, double.infinity);
      mx = List<num>.filled(n, -double.infinity);
      for (var i = 0; i < data.length; i++) {
        final k = i % n;
        if (data[i] < mn[k]) mn[k] = data[i];
        if (data[i] > mx[k]) mx[k] = data[i];
      }
    }
    return _accessor({
      'bufferView': view,
      'componentType': 5126,
      'count': data.length ~/ n,
      'type': type,
      'min': ?mn,
      'max': ?mx,
    });
  }

  int addIndexAccessor(Uint16List data) {
    final view = _view(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      target: 34963,
    );
    return _accessor({
      'bufferView': view,
      'componentType': 5123,
      'count': data.length,
      'type': 'SCALAR',
    });
  }

  int addUByte4Accessor(Uint8List data, {bool normalized = false}) {
    final view = _view(data, target: 34962);
    return _accessor({
      'bufferView': view,
      'componentType': 5121,
      'count': data.length ~/ 4,
      'type': 'VEC4',
      if (normalized) 'normalized': true,
    });
  }

  int addUShort4Accessor(Uint16List data) {
    final view = _view(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      target: 34962,
    );
    return _accessor({
      'bufferView': view,
      'componentType': 5123,
      'count': data.length ~/ 4,
      'type': 'VEC4',
    });
  }

  int addMatrixAccessor(Float32List data) =>
      addFloatAccessor(data, 'MAT4', target: null);

  int _add(String key, Map<String, Object?> v) {
    final l = _list(key)..add(v);
    return l.length - 1;
  }

  int addImage(String uri) => _add('images', {'uri': uri});
  int addSampler({
    required bool nearest,
    required String wrapS,
    required String wrapT,
  }) {
    int wrap(String w) => w == 'repeat' ? 10497 : 33071;
    return _add('samplers', {
      'magFilter': nearest ? 9728 : 9729,
      'minFilter': nearest ? 9728 : 9987,
      'wrapS': wrap(wrapS),
      'wrapT': wrap(wrapT),
    });
  }

  int addTexture(int image, int sampler) =>
      _add('textures', {'source': image, 'sampler': sampler});
  int addMaterial(Map<String, Object?> m) => _add('materials', m);
  int addMesh(
    String name,
    List<Map<String, Object?>> primitives, {
    Map<String, Object?> extras = const {},
  }) => _add('meshes', {
    'name': name,
    'primitives': primitives,
    if (extras.isNotEmpty) 'extras': extras,
  });
  int addNode(Map<String, Object?> n) => _add('nodes', n);
  int addSkin(Map<String, Object?> s) => _add('skins', s);
  int addAnimation(Map<String, Object?> a) => _add('animations', a);

  void setScene(List<int> nodes, {String? name}) {
    json['scenes'] = [
      <String, Object?>{'name': ?name, 'nodes': nodes},
    ];
    json['scene'] = 0;
  }

  Uint8List toGlb() {
    while (_bin.length % 4 != 0) {
      _bin.addByte(0);
    }
    final bin = _bin.toBytes();
    // glTF forbids empty arrays and zero-length buffers: omit them (and the BIN chunk).
    json['buffers'] = bin.isEmpty
        ? null
        : [
            {'byteLength': bin.length},
          ];
    json.removeWhere((k, v) => v == null || (v is List && v.isEmpty));
    final js = utf8.encode(jsonEncode(json));
    final jsonPad = (4 - js.length % 4) % 4;
    final total =
        12 + 8 + js.length + jsonPad + (bin.isEmpty ? 0 : 8 + bin.length);
    final out = BytesBuilder();
    void u32(int v) => out.add(
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little),
    );
    u32(0x46546C67);
    u32(2);
    u32(total);
    u32(js.length + jsonPad);
    u32(0x4E4F534A);
    out
      ..add(js)
      ..add(List.filled(jsonPad, 0x20));
    if (bin.isNotEmpty) {
      u32(bin.length);
      u32(0x004E4942);
      out.add(bin);
    }
    return out.toBytes();
  }
}

({Map<String, Object?> json, Uint8List bin}) readGlb(Uint8List glb) {
  final bd = ByteData.sublistView(glb);
  final jl = bd.getUint32(12, Endian.little);
  final json =
      jsonDecode(utf8.decode(glb.sublist(20, 20 + jl))) as Map<String, Object?>;
  if (glb.length <= 20 + jl) return (json: json, bin: Uint8List(0));
  final bl = bd.getUint32(20 + jl, Endian.little);
  return (json: json, bin: Uint8List.sublistView(glb, 28 + jl, 28 + jl + bl));
}
