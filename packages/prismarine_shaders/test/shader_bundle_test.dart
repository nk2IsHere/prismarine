import 'package:prismarine_shaders/src/shader_bundle.dart';
import 'package:test/test.dart';

void main() {
  test('a dropped block becomes a plain struct of the same name', () {
    const glsl = '''
uniform BufferCamera { uvec4 data[2]; } cb0;
uniform BufferMaterialBase { uvec4 data[3]; } cb3;
uniform BufferObject {
  vec4 sWorldMatrix[3];
} Object;
''';
    final out = unboundBlocksAsStructs(glsl, {'BufferCamera'});
    expect(out, contains('uniform BufferCamera { uvec4 data[2]; } cb0;'));
    expect(
      out,
      contains('struct BufferMaterialBase_unbound { uvec4 data[3]; };'),
    );
    expect(out, contains('BufferMaterialBase_unbound cb3;'));
    expect(out, contains('BufferObject_unbound Object;'));
    expect(out, isNot(contains('uniform BufferObject')));
  });
}
