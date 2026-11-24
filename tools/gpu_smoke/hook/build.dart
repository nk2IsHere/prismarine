import 'package:hooks/hooks.dart';
import 'package:prismarine_cook/prismarine_cook.dart';
import 'package:prismarine_scene/build_hooks.dart';

// Builds smoke.shaderbundle.json for the release 7 checks. Its shaders have
// per-instance attributes and a fragment stage with two outputs. The release 9
// checks use the bundle that prismarine.yaml lists.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundle(
      input: input,
      output: output,
      manifest: 'smoke.shaderbundle.json',
      glesLanguageVersion: 300,
    );
    await cookHook(input, output);
  });
}
