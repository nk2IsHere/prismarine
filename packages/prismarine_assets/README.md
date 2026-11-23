# prismarine_assets

prismarine_assets writes and checks the files of game assets in pure Dart. It builds glTF 2.0 files as GLB, writes
textures as KTX2 and images as PNG and decodes BC1 and BC3 blocks. It also cooks the geometry pools and the texture
arrays of a scene. Every writer gives the same bytes on every OS for the same input. The details are on [the area
page](../../docs/areas/assets.md).

## Usage

`GltfBuilder` holds the JSON of a glTF and one binary buffer. You add accessors with `addFloatAccessor` and
`addIndexAccessor`, then images, samplers, textures, materials, meshes and nodes. `setScene` gives the root nodes, and
`toGlb` returns the GLB. `GltfBuilder.fromGlb` continues an existing file. `readGlb` splits a GLB into its JSON and its
binary chunk. `validateGltf` returns one line for each problem that would make viewers and importers fail, such as an
index past the last vertex.

`encodeKtx2` writes a 2D texture, a texture array, a cube map or a volume texture with all its mip levels in a
`Ktx2Format`. `encodePng` writes RGBA8 pixels as a PNG. `decodeBc1` and `decodeBc3` turn BC blocks into RGBA8 pixels.

`GeometryPools` collects the vertex streams of many meshes into one pool per vertex layout. `cookTextureArrays` groups
the KTX2 textures of a directory into texture arrays by size and format.

## Example

The example writes a textured quad as `quad.glb` and its texture as `checker.png` and `checker.ktx2`. It is
[`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The package is pure Dart. It runs on macOS, Linux and Windows, in any isolate and in command-line tools.
