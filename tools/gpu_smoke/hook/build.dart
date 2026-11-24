import 'package:hooks/hooks.dart';
import 'package:prismarine_cook/prismarine_cook.dart';
import 'package:prismarine_scene/build_hooks.dart';

// Builds the own shaders of the smoke test (smoke.shaderbundle.json) for the
// checks of release 7, with per-instance attributes and a fragment stage with
// two outputs. The bundle of the release 9 checks comes from prismarine.yaml.
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
