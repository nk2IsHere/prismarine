import 'dart:convert';
import 'dart:typed_data';

/// A GLB's JSON and binary chunks (glTF 2.0 §4.4), for reading cooked
/// pools without the converter's builder.
({Map<String, Object?> json, Uint8List bin}) readGlbParts(Uint8List glb) {
  final d = ByteData.sublistView(glb);
  if (glb.length < 20 || d.getUint32(0, Endian.little) != 0x46546C67) {
    throw const FormatException('not a GLB');
  }
  final jl = d.getUint32(12, Endian.little);
  final json =
      jsonDecode(utf8.decode(Uint8List.sublistView(glb, 20, 20 + jl)))
          as Map<String, Object?>;
  if (glb.length <= 20 + jl) return (json: json, bin: Uint8List(0));
  final bl = d.getUint32(20 + jl, Endian.little);
  return (json: json, bin: Uint8List.sublistView(glb, 28 + jl, 28 + jl + bl));
}

/// A cooked pool's index buffer and its streams' bytes by name (each
/// accessor's view, tightly packed as the cook writes them).
({Uint8List indices, Map<String, Uint8List> streams}) cookedPoolParts(
  Uint8List glb,
) {
  final (:json, :bin) = readGlbParts(glb);
  final acc = (json['accessors']! as List).cast<Map<String, Object?>>();
  final views = (json['bufferViews']! as List).cast<Map<String, Object?>>();
  Uint8List bytes(int a) {
    final v = views[acc[a]['bufferView']! as int];
    final at = (v['byteOffset'] as int?) ?? 0;
    return Uint8List.sublistView(bin, at, at + (v['byteLength']! as int));
  }

  final prim = ((json['meshes']! as List).first as Map)['primitives'] as List;
  final p = prim.first as Map;
  return (
    indices: bytes(p['indices']! as int),
    streams: {
      for (final MapEntry(:key, :value)
          in (p['attributes']! as Map).cast<String, int>().entries)
        key: bytes(value),
    },
  );
}
