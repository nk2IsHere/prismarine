/// The fields of a row as the GPU reads them, defined once. The Dart writer
/// takes its offsets from here and [glslStruct] generates the GLSL struct of
/// the effects from it.
///
/// Offsets follow std430. Each field is at the base alignment of its type,
/// 4 for scalars, 8 for vec2 and 16 for vec3, vec4 and matrix rows. The
/// stride of a row is a multiple of 16.
library;

enum FieldType {
  float(4, 'float', align: 4),
  uint(4, 'uint', align: 4),
  sint(4, 'int', align: 4),
  vec2(8, 'vec2', align: 8),
  vec3(12, 'vec3'),
  vec4(16, 'vec4'),
  uvec4(16, 'uvec4'),

  /// Three vec4 rows of a 3 × 4 affine matrix. Row r holds column r of the
  /// 4 × 4 storage, m[r], m[4+r], m[8+r] and m[12+r].
  rows3x4(48, 'vec4');

  const FieldType(this.size, this.glsl, {this.align = 16});
  final int size;
  final String glsl;

  /// The std430 base alignment, in which a vec3 aligns as a vec4.
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

  /// The bytes per row, the fields rounded up to a whole slot.
  late final int stride;

  /// Returns the byte offset of [field] in a row.
  int operator [](String field) =>
      _offsets[field] ?? (throw ArgumentError('$name has no field $field'));

  /// Returns the GLSL struct that the effects declare for this row. Padding
  /// becomes `_padN` members, which give the struct this std430 layout.
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

  /// Returns a GLSL function `<name> load<name>(uint row)` that reads a row
  /// from [words], the `uint` array of a storage buffer (`<instance>.d`).
  /// Shaders bind rows as raw words, which keeps the layout rules of the
  /// compiler from moving a member.
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
