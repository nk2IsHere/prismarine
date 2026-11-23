import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;

/// The kind of a field of a flatbuffer table in the shader bundle schema of
/// impellerc, `impeller/shader_bundle/shader_bundle.fbs`.
enum _F { str, u8, u32, u64, boolean, bytes, u32s, table, tables }

/// The tables of the schema. Each field index has its kind and, for a
/// table, the name of the child table.
const Map<String, List<(_F, String?)>> _schema = {
  'ShaderBundle': [(_F.tables, 'Shader'), (_F.u32, null)],
  'Shader': [
    (_F.str, null),
    (_F.table, 'BackendShader'),
    (_F.table, 'BackendShader'),
    (_F.table, 'BackendShader'),
    (_F.table, 'BackendShader'),
    (_F.table, 'BackendShader'),
  ],
  'BackendShader': [
    (_F.u8, null),
    (_F.str, null),
    (_F.tables, 'ShaderInput'),
    (_F.tables, 'ShaderUniformStruct'),
    (_F.tables, 'ShaderUniformTexture'),
    (_F.bytes, null),
    (_F.bytes, null),
    (_F.tables, 'ShaderStorage'),
    (_F.tables, 'ShaderStorage'),
    (_F.u32s, null),
    (_F.tables, 'ShaderTexelBuffer'),
    (_F.tables, 'ShaderUniformTexture'),
    (_F.tables, 'ShaderUniformTexture'),
    (_F.u32, null),
  ],
  'ShaderInput': [
    (_F.str, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u32, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
  ],
  'ShaderUniformStructField': [
    (_F.str, null),
    (_F.u32, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
  ],
  'ShaderUniformStruct': [
    (_F.str, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.tables, 'ShaderUniformStructField'),
  ],
  // The trailing boolean of these three marks a resource that the stage
  // declares and does not read.
  'ShaderUniformTexture': [
    (_F.str, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.boolean, null),
  ],
  'ShaderTexelBuffer': [
    (_F.str, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.boolean, null),
    (_F.boolean, null),
  ],
  'ShaderStorage': [
    (_F.str, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.u64, null),
    (_F.boolean, null),
    (_F.boolean, null),
  ],
};

/// The backends of a `Shader` table, by field index.
const shaderBundleBackends = {
  'metal_ios': 1,
  'metal_desktop': 2,
  'opengl_es': 3,
  'opengl_desktop': 4,
  'vulkan': 5,
};

/// The `BackendShader` field that holds the compiled code of a backend, a
/// Metal library that the engine loads in place of the source.
const backendShaderCompiled = 6;

/// Returns [bundle] with only the backends in [keep]. An app on Metal loads
/// the `metal_desktop` copy and an app on Vulkan the `vulkan` copy and each
/// backend can be stored in a bundle of its own. [metalCompiled] maps entry
/// names to Metal libraries for the `compiled` field of `metal_desktop`.
Uint8List keepShaderBundleBackends(
  Uint8List bundle,
  Set<String> keep, {
  Map<String, Uint8List> metalCompiled = const {},
}) {
  final r = _Reader(ByteData.sublistView(bundle));
  final b = fb.Builder(initialSize: bundle.length ~/ 2);
  final drop = {
    for (final MapEntry(key: k, value: v) in shaderBundleBackends.entries)
      if (!keep.contains(k)) v,
  };
  final root = _copy(
    r,
    b,
    r.root,
    'ShaderBundle',
    (table, field) => table == 'Shader' && drop.contains(field),
    metalCompiled: metalCompiled,
  );
  b.finish(root, 'IPSB');
  return b.buffer;
}

class _Reader {
  _Reader(this.d);
  final ByteData d;
  int get root => d.getUint32(0, Endian.little);
  int u32(int o) => d.getUint32(o, Endian.little);

  /// The absolute offset of [field] in the table at [t], or null.
  int? field(int t, int field) {
    final vt = t - d.getInt32(t, Endian.little);
    final vtLen = d.getUint16(vt, Endian.little);
    final at = 4 + 2 * field;
    if (at >= vtLen) return null;
    final off = d.getUint16(vt + at, Endian.little);
    return off == 0 ? null : t + off;
  }

  int deref(int o) => o + u32(o);

  /// The number of fields the table at [t] has a vtable slot for, up to its
  /// last present one.
  int fieldCount(int t) {
    final vt = t - d.getInt32(t, Endian.little);
    var n = (d.getUint16(vt, Endian.little) - 4) ~/ 2;
    while (n > 0 && d.getUint16(vt + 4 + 2 * (n - 1), Endian.little) == 0) {
      n--;
    }
    return n;
  }
}

int _copy(
  _Reader r,
  fb.Builder b,
  int t,
  String table,
  bool Function(String table, int field) skip, {
  Map<String, Uint8List> metalCompiled = const {},
  Uint8List? compiled,
}) {
  final fields = _schema[table]!;
  // A field that this schema lacks would be dropped without notice. The
  // schema of impellerc grew and [_schema] must follow it.
  if (r.fieldCount(t) > fields.length) {
    throw FormatException(
      '$table has ${r.fieldCount(t)} fields; the copier knows ${fields.length}',
    );
  }
  // A shader's Metal library goes to its metal_desktop table.
  Uint8List? metalLib;
  if (table == 'Shader' && metalCompiled.isNotEmpty) {
    final at = r.field(t, 0);
    if (at != null) metalLib = metalCompiled[_string(r, r.deref(at))];
  }
  // Children are written before the table that points at them.
  final offs = <int, int>{};
  if (compiled != null) {
    offs[backendShaderCompiled] = b.writeListUint8(compiled);
  }
  for (var i = 0; i < fields.length; i++) {
    final at = r.field(t, i);
    if (at == null || skip(table, i) || offs.containsKey(i)) continue;
    final (kind, child) = fields[i];
    switch (kind) {
      case _F.str:
        offs[i] = b.writeString(_string(r, r.deref(at)));
      case _F.bytes:
        final v = r.deref(at);
        offs[i] = b.writeListUint8(
          Uint8List.fromList(
            r.d.buffer.asUint8List(r.d.offsetInBytes + v + 4, r.u32(v)),
          ),
        );
      case _F.u32s:
        final v = r.deref(at);
        offs[i] = b.writeListUint32([
          for (var k = 0; k < r.u32(v); k++) r.u32(v + 4 + 4 * k),
        ]);
      case _F.table:
        offs[i] = _copy(
          r,
          b,
          r.deref(at),
          child!,
          skip,
          compiled: i == shaderBundleBackends['metal_desktop']
              ? metalLib
              : null,
        );
      case _F.tables:
        final v = r.deref(at);
        final items = [
          for (var k = 0; k < r.u32(v); k++)
            _copy(
              r,
              b,
              r.deref(v + 4 + 4 * k),
              child!,
              skip,
              metalCompiled: metalCompiled,
            ),
        ];
        offs[i] = b.writeList(items);
      case _F.u8 || _F.u32 || _F.u64 || _F.boolean:
        break;
    }
  }
  b.startTable(fields.length);
  for (var i = 0; i < fields.length; i++) {
    final at = r.field(t, i);
    if (offs.containsKey(i) && at == null) b.addOffset(i, offs[i]);
    if (at == null || skip(table, i)) continue;
    switch (fields[i].$1) {
      case _F.u8:
        b.addUint8(i, r.d.getUint8(at));
      case _F.boolean:
        b.addBool(i, r.d.getUint8(at) != 0);
      case _F.u32:
        b.addUint32(i, r.u32(at));
      case _F.u64:
        b.addUint64(i, r.d.getUint64(at, Endian.little));
      default:
        b.addOffset(i, offs[i]);
    }
  }
  return b.endTable();
}

String _string(_Reader r, int s) => String.fromCharCodes(
  r.d.buffer.asUint8List(r.d.offsetInBytes + s + 4, r.u32(s)),
);

/// Returns [bundle] as nested lists, with the fields of each table by index.
Object? decodeShaderBundle(Uint8List bundle) {
  final r = _Reader(ByteData.sublistView(bundle));
  Object? table(int t, String name) {
    final fields = _schema[name]!;
    return [
      for (var i = 0; i < fields.length; i++)
        () {
          final at = r.field(t, i);
          if (at == null) return null;
          final (kind, child) = fields[i];
          return switch (kind) {
            _F.u8 || _F.boolean => r.d.getUint8(at),
            _F.u32 => r.u32(at),
            _F.u64 => r.d.getUint64(at, Endian.little),
            _F.str || _F.bytes => () {
              final v = r.deref(at);
              return r.d.buffer
                  .asUint8List(r.d.offsetInBytes + v + 4, r.u32(v))
                  .toList();
            }(),
            _F.u32s => () {
              final v = r.deref(at);
              return [for (var k = 0; k < r.u32(v); k++) r.u32(v + 4 + 4 * k)];
            }(),
            _F.table => table(r.deref(at), child!),
            _F.tables => () {
              final v = r.deref(at);
              return [
                for (var k = 0; k < r.u32(v); k++)
                  table(r.deref(v + 4 + 4 * k), child!),
              ];
            }(),
          };
        }(),
    ];
  }

  return table(r.root, 'ShaderBundle');
}
