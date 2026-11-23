import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

void main() {
  group('RowLayout', () {
    test('fields follow std430 alignment', () {
      final l = RowLayout('T', const [
        RowField('a', FieldType.float),
        RowField('b', FieldType.vec2),
        RowField('c', FieldType.vec3),
        RowField('d', FieldType.float),
        RowField('e', FieldType.rows3x4),
        RowField('f', FieldType.uint),
      ]);
      expect(
        [l['a'], l['b'], l['c'], l['d'], l['e'], l['f']],
        [0, 8, 16, 28, 32, 80],
      );
      expect(l.stride, 96);
    });

    test('the GLSL struct pads to the same offsets', () {
      final l = RowLayout('T', const [
        RowField('a', FieldType.float),
        RowField('b', FieldType.vec2),
        RowField('m', FieldType.rows3x4),
      ]);
      expect(
        l.glslStruct(),
        'struct T {\n  float a;\n  float _pad0;\n  vec2 b;\n'
        '  vec4 m[3];\n};\n',
      );
    });

    test('the loader reads each member from its words', () {
      final l = RowLayout('T', const [
        RowField('a', FieldType.float),
        RowField('n', FieldType.sint),
        RowField('m', FieldType.rows3x4),
      ]);
      expect(
        l.glslLoader('rows.d'),
        'T loadT(uint row) {\n'
        '  uint b = row * 16u;\n'
        '  T r;\n'
        '  r.a = uintBitsToFloat(rows.d[b + 0u]);\n'
        '  r.n = int(rows.d[b + 1u]);\n'
        '  r.m[0] = uintBitsToFloat(uvec4(rows.d[b + 4u], rows.d[b + 5u], '
        'rows.d[b + 6u], rows.d[b + 7u]));\n'
        '  r.m[1] = uintBitsToFloat(uvec4(rows.d[b + 8u], rows.d[b + 9u], '
        'rows.d[b + 10u], rows.d[b + 11u]));\n'
        '  r.m[2] = uintBitsToFloat(uvec4(rows.d[b + 12u], rows.d[b + 13u], '
        'rows.d[b + 14u], rows.d[b + 15u]));\n'
        '  return r;\n}\n',
      );
    });

    test('the scene rows keep whole slots', () {
      for (final l in [objectRow, instanceRow]) {
        expect(l.stride % 16, 0, reason: l.name);
      }
      // The rows' leading members keep BufferObject's and BufferInstance's
      // std140 offsets, which std430 shares here.
      expect(objectRow['sObjectDiffuseColor'], 128);
      expect(objectRow['sObjectRimBumpDepth'], 140);
      expect(objectRow['pad0'], 220);
      expect(objectRow['sStencilRef'], 224);
      expect(instanceRow['sLightmapPageIndex'], 124);
    });
  });

  group('RowTable', () {
    test('reuses freed rows and zeroes them', () {
      final t = RowTable(16, capacity: 2);
      final a = t.take();
      t.setUint(a, 0, 7);
      t.free(a);
      expect(t.take(), a);
      expect(t.getUint(a, 0), 0);
      expect(t.live, 1);
    });

    test('marks one dirty range per frame', () {
      final t = RowTable(16, capacity: 8);
      for (var i = 0; i < 4; i++) {
        t.take();
      }
      t.takeDirty();
      expect(t.takeDirty(), isNull);
      t.setFloat(1, 4, 1.5);
      t.setFloat(3, 0, 2);
      expect(t.takeDirty(), (start: 16, end: 64, whole: false));
      expect(t.takeDirty(), isNull);
    });

    test('grows by doubling, keeps rows and says the buffer is new', () {
      final t = RowTable(16, capacity: 1);
      final a = t.take();
      t.setFloats(a, 0, [1, 2, 3, 4]);
      t.takeDirty();
      t.take();
      expect(t.capacity, 2);
      expect(t.takeDirty(), (start: 0, end: 32, whole: true));
      expect(t.bytes.getFloat32(8, Endian.little), 3);
    });
  });
}
