import 'package:prismarine_shaders/src/cli.dart';
import 'package:test/test.dart';

void main() {
  test('the default settings have Metal and Vulkan and no options', () {
    final s = bundleSettings(bundleArgParser().parse(const []));
    expect(s.backends, {'metal_desktop': 'metal', 'vulkan': 'vulkan'});
    expect(s.impellercArgs, isEmpty);
    expect(s.entryOptions, isEmpty);
  });

  test('options keep their order and booleans parse', () {
    final s = bundleSettings(
      bundleArgParser().parse(const [
        '--backend=vulkan=vk',
        '--impellerc-arg=--metal-version=2.3',
        '--option=metal_preserve_invariance=true',
        '--option=metal_safe_math=false',
        '--option=spirv_optimize=true',
      ]),
    );
    expect(s.backends, {'vulkan': 'vk'});
    expect(s.impellercArgs, ['--metal-version=2.3']);
    expect(
      '${s.entryOptions}',
      '{metal_preserve_invariance: true, metal_safe_math: false, '
          'spirv_optimize: true}',
    );
  });

  test('a pair without a value is refused', () {
    expect(
      () => bundleSettings(bundleArgParser().parse(const ['--option=x'])),
      throwsFormatException,
    );
  });

  test('a run without a command prints the usage', () async {
    final out = StringBuffer();
    expect(await runShadersCli(const [], out), 64);
    expect(out.toString(), contains('prismarine_shaders bundle <root>'));
  });
}
