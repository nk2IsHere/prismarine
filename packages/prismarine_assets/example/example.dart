import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';

void main() {
  // A textured quad as a GLB file.
  final gltf = GltfBuilder(generator: 'quad example');
  final position = gltf.addFloatAccessor(
    Float32List.fromList([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]),
    'VEC3',
    minMax: true,
  );
  final uv = gltf.addFloatAccessor(
    Float32List.fromList([0, 1, 1, 1, 1, 0, 0, 0]),
    'VEC2',
  );
  final indices = gltf.addIndexAccessor(
    Uint16List.fromList([0, 1, 2, 0, 2, 3]),
  );
  final texture = gltf.addTexture(
    gltf.addImage('checker.png'),
    gltf.addSampler(nearest: true, wrapS: 'repeat', wrapT: 'repeat'),
  );
  final material = gltf.addMaterial({
    'pbrMetallicRoughness': {
      'baseColorTexture': {'index': texture},
    },
  });
  final mesh = gltf.addMesh('quad', [
    {
      'attributes': {'POSITION': position, 'TEXCOORD_0': uv},
      'indices': indices,
      'material': material,
    },
  ]);
  gltf.setScene([
    gltf.addNode({'mesh': mesh}),
  ]);
  final glb = gltf.toGlb();

  final (:json, :bin) = readGlb(glb);
  final problems = validateGltf(json, bin);
  if (problems.isNotEmpty) throw StateError(problems.join('\n'));
  File('quad.glb').writeAsBytesSync(glb);

  // An 8×8 checker texture as PNG and as KTX2.
  final pixels = Uint8List(8 * 8 * 4);
  for (var i = 0; i < 64; i++) {
    final v = (i ~/ 8 + i % 8).isEven ? 255 : 40;
    pixels.setAll(i * 4, [v, v, v, 255]);
  }
  File('checker.png').writeAsBytesSync(encodePng(8, 8, pixels));
  File('checker.ktx2').writeAsBytesSync(
    encodeKtx2(
      format: Ktx2Format.rgba8Srgb,
      width: 8,
      height: 8,
      levels: [pixels],
    ),
  );
  print('wrote quad.glb (${glb.length} bytes), checker.png and checker.ktx2');
}
