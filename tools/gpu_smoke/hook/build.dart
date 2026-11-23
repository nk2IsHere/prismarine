import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

// The smoke test's own shaders (smoke.shaderbundle.json) for the checks of
// release 7: per-instance attributes and a fragment stage with two outputs.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildTargetShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'smoke.shaderbundle.json',
      glesLanguageVersion: 300,
    );
  });
}
