# prismarine_shaders

prismarine_shaders builds the shader bundles of a game ahead of time with impellerc, the shader compiler of the Flutter
engine. It needs the impellerc of the patched engine, which accepts large uniform blocks, storage resources and a list
of backends for each entry. You use it as a Dart library or through its command line. The details are on [the area
page](../../docs/areas/shaders.md).

## Usage

A program tree has a folder for each effect under `programs/`, such as `programs/Mesh/` with `unlit.vert` and
`unlit.frag`. Every file is one bundle entry with the id `<effect>/<file>`. Its extension gives its stage.
`buildShaderBundles` builds each effect in shards and writes one gzip-compressed bundle for each backend of the
`ShaderBundleSettings`, such as `bundle/vulkan/Mesh.0.shaderbundle.gz`. The sources of a shard then move to
`programs/Mesh/0/`. On macOS each Metal entry also carries a Metal library that Xcode compiles. The engine then compiles
no shader at run time.

`findImpellerc` returns the impellerc in `PRISMARINE_IMPELLERC`. With a `cacheDir`, a shard whose sources and tools have
not changed comes from the cache.

`shaderInterface` reads the interface of a GLSL source, its uniform blocks, textures, samplers and vertex inputs, in the
JSON form that `ShaderRecord` of prismarine_frame reads.

The command line builds bundles too:

```sh
dart run prismarine_shaders bundle <root> --cache=<cache folder>
```

## Example

The example builds a tree with one effect for Metal and Vulkan. A second run takes the shard from the cache. It is
[`example/example.dart`](example/example.dart):

```dart
import 'dart:io';

import 'package:prismarine_shaders/prismarine_shaders.dart';

const vertex = '''
#version 460 core
layout(location = 0) in vec3 position;
layout(location = 1) in vec2 uv0;
uniform Camera {
  mat4 viewProjection;
} camera;
layout(location = 0) out vec2 uv;
void main() {
  uv = uv0;
  gl_Position = camera.viewProjection * vec4(position, 1.0);
}
''';

const fragment = '''
#version 460 core
precision highp float;
uniform sampler2D baseColor;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 colour;
void main() { colour = texture(baseColor, uv); }
''';

/// Builds a program tree with one effect, `Mesh`, into a bundle for Metal
/// and one for Vulkan. A second run takes the shard from the cache.
Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('shaders').path;
  File('$root/programs/Mesh/unlit.vert')
    ..createSync(recursive: true)
    ..writeAsStringSync(vertex);
  File('$root/programs/Mesh/unlit.frag').writeAsStringSync(fragment);

  final impellerc = findImpellerc();
  if (impellerc == null) {
    print('set PRISMARINE_IMPELLERC to the impellerc of the patched engine');
    return;
  }
  final report = await buildShaderBundles(
    root,
    const ShaderBundleSettings(
      backends: {'metal_desktop': 'metal', 'vulkan': 'vulkan'},
    ),
    impellerc: impellerc,
    cacheDir: '.shader_cache',
  );
  print(
    '${report.bundled} entries, ${report.cached} from the cache, '
    'failed: ${report.failed}',
  );
}
```

## Platforms

The package is pure Dart and runs where the impellerc of the engine runs, on macOS, Linux and Windows. The Metal
libraries are compiled only on macOS with Xcode.
