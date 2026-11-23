import 'dart:io';

import 'package:prismarine_shaders/prismarine_shaders.dart';
import 'package:test/test.dart';

void main() {
  test('records resolve includes and ifdef blocks and skip bodies', () {
    final root = Directory.systemTemp.createTempSync('records').path;
    File('$root/Mesh/bodies/frame.glsl')
      ..createSync(recursive: true)
      ..writeAsStringSync('uniform Frame {\n  mat4 m;\n} cb0;\n');
    File('$root/Mesh/lit.frag').writeAsStringSync('''
#version 460 core
#define SHADOWS
#include "Mesh/bodies/frame.glsl"
#ifdef SHADOWS
uniform texture2D shadowMap; // t4
#else
uniform texture2D flat; // t5
#endif
void main() { vec4 x = cb0.m[0]; }
''');
    final r = programRecords(root);
    expect(r.keys, ['Mesh/lit.frag']);
    final rec = r['Mesh/lit.frag']! as Map;
    expect('$rec', contains('shadowMap'));
    expect('$rec', isNot(contains('flat')));
    expect('$rec', contains('Frame'));
    Directory(root).deleteSync(recursive: true);
  });
}
