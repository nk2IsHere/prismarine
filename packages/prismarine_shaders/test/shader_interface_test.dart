import 'package:prismarine_shaders/prismarine_shaders.dart';
import 'package:test/test.dart';

const _vertex = '''#version 460 core
uniform Frame {
  mat4 viewProjection;
  vec3 camera;
  float exposure;
  vec4 lights[16];
} cb0;
uniform Unused {
  vec4 x;
} cb1;
layout(location = 0) in vec3 vsi0_POSITION0;
layout(location = 1) in vec2 vsi3_TEXCOORD0;
void main() { gl_Position = cb0.viewProjection * vec4(vsi0_POSITION0, 1.0); }
''';

const _pixel = '''#version 460 core
uniform texture2D baseColor; // t0
uniform sampler s0;
#define baseColor_S s0
uniform texture2D shadowMap; // t4
uniform samplerShadow s4;
#define shadowMap_S s4
void main() {}
''';

void main() {
  test('blocks have their std140 rows and slot, unread blocks none', () {
    final i = shaderInterface(_vertex, 'vertex');
    expect(i['blocks'], [
      {'name': 'Frame', 'parameter': null, 'slot': 0, 'rows': 4 + 1 + 16},
    ]);
    final a = (i['attributes'] as List).cast<Map>();
    expect(a.map((x) => (x['register'], x['semantic'], x['index'])), [
      (0, 'POSITION', 0),
      (3, 'TEXCOORD', 0),
    ]);
    expect(a[1]['name'], 'vsi3_TEXCOORD0');
  });

  test('textures pair with their samplers', () {
    final i = shaderInterface(_pixel, 'pixel');
    expect((i['textures'] as List).map((t) => (t['name'], t['slot'])), [
      ('baseColor', 0),
      ('shadowMap', 4),
    ]);
    expect((i['samplers'] as List).map((s) => (s['slot'], s['comparison'])), [
      (0, false),
      (4, true),
    ]);
    expect((i['bindings'] as List).map((b) => b['sampler']), [0, 4]);
  });

  test('std140Rows aligns vec3 to 16 bytes', () {
    expect(std140Rows('vec3 a; vec3 b;'), 2);
    expect(std140Rows('vec3 a; float b;'), 1);
    expect(std140Rows('float a; vec2 b; mat3 c;'), 4);
  });

  test('storage images may have access qualifiers', () {
    final i = shaderInterface('''
layout(rgba16f) uniform writeonly image2D rays;
layout(rgba16f) uniform image2D atlas;
layout(std430) readonly buffer RawVoxels { uint words[]; } voxels;
void main() {}
''', 'compute');
    expect(i['storage'], {
      'rays': 'image2D',
      'atlas': 'image2D',
      'RawVoxels': 'buffer',
    });
    expect(i['readonly'], ['RawVoxels']);
  });
}
