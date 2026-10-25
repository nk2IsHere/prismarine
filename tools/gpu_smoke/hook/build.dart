import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

// The smoke test's own shaders (smoke.shaderbundle.json): per-instance
// attributes and a fragment stage with two outputs (mcsm7 checks).
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
