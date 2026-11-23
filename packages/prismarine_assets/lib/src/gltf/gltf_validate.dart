import 'dart:math';
import 'dart:typed_data';

const _compSize = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4};
const _typeSize = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16};

/// Structural checks we rely on (not a full Khronos validator).
List<String> validateGltf(Map<String, Object?> json, Uint8List bin) {
  final p = <String>[];
  final views = (json['bufferViews'] as List? ?? const []).cast<Map>();
  final accs = (json['accessors'] as List? ?? const []).cast<Map>();
  for (var i = 0; i < views.length; i++) {
    final v = views[i];
    final off = (v['byteOffset'] as int?) ?? 0, len = v['byteLength'] as int;
    if (off + len > bin.length) p.add('bufferView $i exceeds buffer');
    if (len < 1) p.add('bufferView $i has byteLength 0');
  }
  for (var i = 0; i < accs.length; i++) {
    final a = accs[i];
    if ((a['count'] as int) < 1) p.add('accessor $i has count 0');
    final v = views[a['bufferView'] as int];
    final need =
        (a['count'] as int) *
        _compSize[a['componentType']]! *
        _typeSize[a['type']]!;
    if (need > (v['byteLength'] as int)) {
      p.add('accessor $i exceeds bufferView ${a['bufferView']}');
    }
  }
  int count(int acc) => accs[acc]['count'] as int;
  List<int> ushorts(int acc) {
    final v = views[accs[acc]['bufferView'] as int];
    final off = (v['byteOffset'] as int?) ?? 0;
    final bd = ByteData.sublistView(bin, off);
    return [
      for (var k = 0; k < count(acc) * _typeSize[accs[acc]['type']]!; k++)
        bd.getUint16(k * 2, Endian.little),
    ];
  }

  Float32List floats(int acc) {
    final v = views[accs[acc]['bufferView'] as int];
    final off = (v['byteOffset'] as int?) ?? 0;
    final bd = ByteData.sublistView(bin, off);
    return Float32List.fromList([
      for (var k = 0; k < count(acc) * _typeSize[accs[acc]['type']]!; k++)
        bd.getFloat32(k * 4, Endian.little),
    ]);
  }

  void noEmpty(Object? v, String path) {
    if (v is List) {
      if (v.isEmpty) p.add('$path: empty array (glTF forbids empty entities)');
      for (var i = 0; i < v.length; i++) {
        noEmpty(v[i], '$path/$i');
      }
    } else if (v is Map) {
      for (final e in v.entries) {
        if (e.key == 'extras') continue;
        noEmpty(e.value, '$path/${e.key}');
      }
    }
  }

  noEmpty(json, '');
  final skins = (json['skins'] as List? ?? const []).cast<Map>();
  for (final m in (json['meshes'] as List? ?? const []).cast<Map>()) {
    for (final prim in (m['primitives'] as List).cast<Map>()) {
      final attrs = (prim['attributes'] as Map).cast<String, int>();
      final vcount = count(attrs['POSITION']!);
      for (final e in attrs.entries) {
        if (count(e.value) != vcount) {
          p.add('${m['name']}: ${e.key} count ${count(e.value)} != $vcount');
        }
        // Indexed semantics (TEXCOORD_n, COLOR_n, ...) must be numbered contiguously from 0.
        final us = e.key.lastIndexOf('_');
        final n = us > 0 ? int.tryParse(e.key.substring(us + 1)) : null;
        if (n != null && n > 0 && !e.key.startsWith('_')) {
          final prev = '${e.key.substring(0, us)}_${n - 1}';
          if (!attrs.containsKey(prev)) {
            p.add('${m['name']}: ${e.key} without $prev');
          }
        }
      }
      if (prim['indices'] != null) {
        for (final ix in ushorts(prim['indices'] as int)) {
          if (ix >= vcount) {
            p.add('${m['name']}: index $ix >= vertex count $vcount');
            break;
          }
        }
      }
      if (attrs['NORMAL'] != null) {
        final f = floats(attrs['NORMAL']!);
        for (var v = 0; v * 3 < f.length; v++) {
          final l = sqrt(
            f[v * 3] * f[v * 3] +
                f[v * 3 + 1] * f[v * 3 + 1] +
                f[v * 3 + 2] * f[v * 3 + 2],
          );
          if ((l - 1).abs() > 1e-3) {
            p.add('${m['name']}: NORMAL $v not unit length ($l)');
            break;
          }
        }
      }
      if (attrs['TANGENT'] != null) {
        final f = floats(attrs['TANGENT']!);
        for (var v = 0; v * 4 < f.length; v++) {
          final l = sqrt(
            f[v * 4] * f[v * 4] +
                f[v * 4 + 1] * f[v * 4 + 1] +
                f[v * 4 + 2] * f[v * 4 + 2],
          );
          if ((l - 1).abs() > 1e-3) {
            p.add('${m['name']}: TANGENT $v xyz not unit length ($l)');
            break;
          }
          if (f[v * 4 + 3].abs() != 1) {
            p.add('${m['name']}: TANGENT $v w is not ±1 (${f[v * 4 + 3]})');
            break;
          }
        }
      }
      if (attrs['JOINTS_0'] != null && skins.isNotEmpty) {
        final nj = (skins.first['joints'] as List).length;
        for (final j in ushorts(attrs['JOINTS_0']!)) {
          if (j >= nj) {
            p.add('${m['name']}: joint $j >= skin joints $nj');
            break;
          }
        }
      }
    }
  }
  final nodes = (json['nodes'] as List? ?? const []);
  // glTF: a skinned mesh node's transform is ignored, so it must not be anyone's child.
  final childOf = {
    for (final n in nodes.cast<Map>())
      ...((n['children'] as List?) ?? const []),
  };
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i] as Map;
    if (n['skin'] != null && n['mesh'] != null && childOf.contains(i)) {
      p.add('skinned mesh node $i is not a root');
    }
  }
  final anims = (json['animations'] as List? ?? const []).cast<Map>();
  for (var ai = 0; ai < anims.length; ai++) {
    final samplers = (anims[ai]['samplers'] as List).cast<Map>();
    for (final ch in (anims[ai]['channels'] as List).cast<Map>()) {
      final si = ch['sampler'] as int;
      final target = ch['target'] as Map;
      final node = target['node'] as int?, path = target['path'];
      if (si >= samplers.length) {
        p.add('animation $ai: channel sampler $si missing');
        continue;
      }
      if (node == null || node >= nodes.length) {
        p.add('animation $ai: target node $node missing');
      }
      if (!const {
        'translation',
        'rotation',
        'scale',
        'weights',
      }.contains(path)) {
        p.add('animation $ai: bad target path $path');
      }
      final s = samplers[si];
      final input = s['input'] as int, output = s['output'] as int;
      if (accs[input]['min'] == null || accs[input]['max'] == null) {
        p.add('animation $ai: input accessor $input lacks min/max');
      }
      final t = floats(input);
      for (var k = 1; k < t.length; k++) {
        if (!(t[k] > t[k - 1])) {
          p.add(
            'animation $ai: input accessor $input not strictly increasing at $k',
          );
          break;
        }
      }
      if ((s['interpolation'] ?? 'LINEAR') != 'CUBICSPLINE' &&
          count(output) != count(input)) {
        p.add(
          'animation $ai: output count ${count(output)} != input count ${count(input)}',
        );
      }
      if (path == 'rotation') {
        final q = floats(output);
        for (var k = 0; k * 4 < q.length; k++) {
          final l = sqrt(
            q[k * 4] * q[k * 4] +
                q[k * 4 + 1] * q[k * 4 + 1] +
                q[k * 4 + 2] * q[k * 4 + 2] +
                q[k * 4 + 3] * q[k * 4 + 3],
          );
          if ((l - 1).abs() > 1e-3) {
            p.add('animation $ai: rotation key $k not unit length ($l)');
            break;
          }
        }
      }
    }
  }
  return p;
}
