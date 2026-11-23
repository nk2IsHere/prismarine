import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_shaders/src/metal_compile.dart';
import 'package:test/test.dart';

const _options = {
  'metal_preserve_invariance': true,
  'metal_safe_math': false,
  'spirv_optimize': true,
};

void main() {
  test('only blocks with a buffer binding count', () {
    const msl = '''
struct BufferCamera { uint4 data[2]; };
struct BufferMaterialMain { uint4 data[2]; };
fragment main0_out main0(main0_in in [[stage_in]],
    constant BufferScene& cb1 [[buffer(1)]],
    constant BufferCamera& cb0 [[buffer(0)]],
    device RawU0& u0 [[buffer(2)]],
    texture2d<float> t0 [[texture(0)]])
''';
    expect(metalBoundBlocks(Uint8List.fromList(utf8.encode(msl))), [
      'BufferCamera',
      'BufferScene',
    ]);
  });

  test(
    "an entry with invariance compiles with the engine's run-time options",
    () {
      expect(metalCompileFlags(_options), [
        '-std=macos-metal2.3',
        '-fpreserve-invariance',
      ]);
      expect(metalCompileFlags(const {}), isEmpty);
      expect(
        metalCompileFlags(const {'metal_safe_math': true}),
        contains('-fmetal-math-mode=safe'),
      );
    },
  );

  final metal = MetalCompiler.find();
  test('a library starts with MTLB and the same source gives the same bytes '
      'wherever it is compiled', () async {
    final dir = Directory.systemTemp.createTempSync('metal_compile');
    try {
      final msl = Uint8List.fromList(
        utf8.encode(
          '#include <metal_stdlib>\nusing namespace metal;\n'
          'fragment float4 f0() { return float4(1.0); }\n',
        ),
      );
      final flags = metalCompileFlags(_options);
      final (a, errA) = await metal!.compile(msl, '${dir.path}/a', flags);
      final (b, errB) = await metal.compile(msl, '${dir.path}/b', flags);
      expect([errA, errB], [null, null]);
      expect(String.fromCharCodes(a!.take(4)), 'MTLB');
      expect(b, a);
      expect(Directory('${dir.path}/a').listSync(), isEmpty);
      final (none, err) = await metal.compile(
        Uint8List.fromList(utf8.encode('not metal')),
        '${dir.path}/c',
        flags,
      );
      expect(none, isNull);
      expect(err, contains('error'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: metal == null ? "Apple's Metal compiler is not installed" : false);
}
