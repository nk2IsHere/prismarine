import 'package:hooks/hooks.dart';
import 'package:prismarine_scene/build_hooks.dart';

// Builds the shaders of the screen copy.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundle(
      input: input,
      output: output,
      manifest: 'screen_copy.shaderbundle.json',
    );
  });
}
