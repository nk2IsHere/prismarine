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
