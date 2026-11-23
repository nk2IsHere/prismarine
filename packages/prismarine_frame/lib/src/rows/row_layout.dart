/// A row's fields as the GPU reads them, defined once: the Dart writer
/// takes its offsets from here and the effects' GLSL struct is generated
/// from it ([glslStruct]), so the two can't drift apart.
///
/// Offsets follow std430: each field at its type's base alignment (4 for
/// scalars, 8 for vec2, 16 for vec3, vec4 and matrix rows), and a row's
/// stride a multiple of 16.
library;

enum FieldType {
  float(4, 'float', align: 4),
  uint(4, 'uint', align: 4),
  sint(4, 'int', align: 4),
  vec2(8, 'vec2', align: 8),
  vec3(12, 'vec3'),
  vec4(16, 'vec4'),
  uvec4(16, 'uvec4'),

  /// Three vec4 rows of a 3 × 4 affine matrix (row r holds column r of the
  /// 4 × 4 storage: m[r], m[4+r], m[8+r], m[12+r]), as BufferObject's world
  /// rows are laid out (formats/s2/shaders.md "BufferObject").
  rows3x4(48, 'vec4');

  const FieldType(this.size, this.glsl, {this.align = 16});
  final int size;
  final String glsl;

  /// std430's base alignment: a vec3 aligns as a vec4.
  final int align;
}

class RowField {
  const RowField(this.name, this.type);
  final String name;
  final FieldType type;
}

class RowLayout {
  RowLayout(this.name, List<RowField> fields)
    : fields = List.unmodifiable(fields) {
    var o = 0;
    for (final f in this.fields) {
      final a = f.type.align;
      o = (o + a - 1) ~/ a * a;
      _offsets[f.name] = o;
      o += f.type.size;
    }
    stride = (o + 15) & ~15;
  }

  final String name;
  final List<RowField> fields;
  final _offsets = <String, int>{};

  /// Bytes per row: the fields rounded up to a whole slot.
  late final int stride;

  /// [field]'s byte offset in a row.
  int operator [](String field) =>
      _offsets[field] ?? (throw ArgumentError('$name has no field $field'));

  /// The GLSL struct the effects declare for this row; padding becomes
  /// named `_padN` members so the struct's std430 layout is this one.
  String glslStruct() {
    final b = StringBuffer('struct $name {\n');
    var o = 0;
    var pad = 0;
    for (final f in fields) {
      final at = this[f.name];
      while (o < at) {
        b.writeln('  float _pad${pad++};');
        o += 4;
      }
      if (f.type == FieldType.rows3x4) {
        b.writeln('  vec4 ${f.name}[3];');
      } else {
        b.writeln('  ${f.type.glsl} ${f.name};');
      }
      o += f.type.size;
    }
    while (o < stride) {
      b.writeln('  float _pad${pad++};');
      o += 4;
    }
    b.write('};\n');
    return b.toString();
  }

  /// A GLSL function `<name> load<name>(uint row)` that reads row [row]
  /// from [words], a storage buffer's `uint` array (`<instance>.d`): shaders
  /// bind rows as raw words, so no struct layout rule of the compiler can
  /// move a member.
  String glslLoader(String words) {
    final b = StringBuffer('$name load$name(uint row) {\n')
      ..writeln('  uint b = row * ${stride ~/ 4}u;')
      ..writeln('  $name r;');
    String w(int i) => '$words[b + ${i}u]';
    String floats(int at, int n) => n == 1
        ? 'uintBitsToFloat(${w(at)})'
        : 'uintBitsToFloat(uvec$n(${[for (var i = 0; i < n; i++) w(at + i)].join(', ')}))';
    for (final f in fields) {
      final at = this[f.name] ~/ 4;
      final v = switch (f.type) {
        FieldType.float => floats(at, 1),
        FieldType.uint => w(at),
        FieldType.sint => 'int(${w(at)})',
        FieldType.vec2 => floats(at, 2),
        FieldType.vec3 => floats(at, 3),
        FieldType.vec4 => floats(at, 4),
        FieldType.uvec4 =>
          'uvec4(${[for (var i = 0; i < 4; i++) w(at + i)].join(', ')})',
        FieldType.rows3x4 => null,
      };
      if (v != null) {
        b.writeln('  r.${f.name} = $v;');
      } else {
        for (var r = 0; r < 3; r++) {
          b.writeln('  r.${f.name}[$r] = ${floats(at + 4 * r, 4)};');
        }
      }
    }
    b.write('  return r;\n}\n');
    return b.toString();
  }
}
