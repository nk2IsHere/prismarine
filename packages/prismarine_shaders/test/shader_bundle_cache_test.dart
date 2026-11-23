import 'dart:io';

import 'package:prismarine_shaders/prismarine_shaders.dart';
import 'package:test/test.dart';

const _settings = ShaderBundleSettings(
  backends: {'metal_desktop': 'metal', 'vulkan': 'vulkan'},
  impellercArgs: ['--metal-version=2.3'],
  entryOptions: {'metal_preserve_invariance': true},
);

String _glsl(String swizzle) =>
    '#version 460 core\n'
    'precision highp float;\n'
    'layout(location = 0) in vec4 psi0;\n'
    'layout(location = 0) out vec4 pso0;\n'
    'void main() { pso0 = psi0 * psi0.$swizzle + psi0; }\n';

void main() {
  final imp = findImpellerc();

  test('an entry carries its type, the targets and the entry options', () {
    expect(_settings.entry('a/b.vert', 'vert'), {
      'type': 'vertex',
      'file': 'a/b.vert',
      'targets': ['metal_desktop', 'vulkan'],
      'metal_preserve_invariance': true,
    });
    expect(_settings.entry('c.comp', 'compute')['type'], 'compute');
    expect(_settings.entry('d.frag', 'frag')['type'], 'fragment');
  });

  test('a shard with unchanged sources comes from the cache with the same '
      'bundles and sources as compiled', () async {
    final dir = Directory.systemTemp.createTempSync('shader_bundle_cache');
    try {
      final cache = '${dir.path}/cache';
      Map<String, List<int>> files(String root) => {
        for (final f
            in Directory(root)
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => !f.path.endsWith('build.log')))
          f.path.substring(root.length): f.readAsBytesSync(),
      };
      final out = <Map<String, List<int>>>[];
      final reports = <ShaderBundleReport>[];
      for (final run in ['a', 'b']) {
        final root = '${dir.path}/$run';
        File('$root/programs/X/one.frag')
          ..createSync(recursive: true)
          ..writeAsStringSync(_glsl('wzyx'));
        File('$root/programs/X/two.frag').writeAsStringSync(_glsl('yxwz'));
        reports.add(
          await buildShaderBundles(
            root,
            _settings,
            impellerc: imp!,
            cacheDir: cache,
          ),
        );
        out.add(files(root));
      }
      expect([for (final r in reports) r.bundled], [2, 2]);
      expect([for (final r in reports) r.cached], [0, 2]);
      expect(out[0].keys, contains('/bundle/vulkan/X.0.shaderbundle.gz'));
      expect(out[0].keys, contains('/programs/X/0/one.frag'));
      expect(out[1].keys.toSet(), out[0].keys.toSet());
      for (final k in out[0].keys) {
        expect(out[1][k], out[0][k], reason: k);
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: imp == null ? 'needs PRISMARINE_IMPELLERC' : null);
}
