import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';
import 'package:prismarine_shaders/prismarine_shaders.dart';

/// Builds the shader bundle of the manifest file [manifest] of the package
/// into `build/shaderbundles/<name>.shaderbundle`. The package lists
/// `build/shaderbundles/` as an asset and loads the bundle as
/// `packages/<package>/build/shaderbundles/<name>.shaderbundle`.
///
/// The bundle keeps the backends of the target, `metal_desktop` on macOS and
/// `vulkan` on Linux, Windows and Android. A vertex output whose name ends
/// in `viewport_index` picks the viewport on Metal. On macOS each Metal
/// entry also carries a Metal library compiled by the Metal compiler of
/// Xcode. Without the compiler the bundle carries the source alone.
/// [includeDirectories] are searched for the files that a shader includes.
/// [glesLanguageVersion] sets the GLSL version of the OpenGL ES copy that
/// impellerc writes before the backends are kept.
Future<void> buildShaderBundle({
  required BuildInput input,
  required BuildOutputBuilder output,
  required String manifest,
  List<Uri> includeDirectories = const [],
  int? glesLanguageVersion,
}) async {
  final result = await buildShaderBundleJson(
    buildInput: input,
    buildOutput: output,
    manifestFileName: manifest,
    includeDirectories: includeDirectories,
    glesLanguageVersion: glesLanguageVersion,
  );
  final file = File.fromUri(result.outputFile);
  final bytes = file.readAsBytesSync();
  final keep = shaderBackendsFor(_targetOS(input));
  final sources = <String, Uint8List>{};
  final libraries = <String, Uint8List>{};
  if (keep.contains('metal_desktop')) {
    final metal = MetalCompiler.find();
    final scratch = input.outputDirectory.resolve('metal/').toFilePath();
    for (final MapEntry(key: name, value: msl) in metalSources(bytes).entries) {
      final source = metalViewportIndex(msl);
      if (source != null) sources[name] = source;
      if (metal == null) continue;
      final (library, error) = await metal.compile(
        source ?? msl,
        '$scratch$name',
        const [],
      );
      if (library == null) {
        throw StateError('$manifest: $name does not compile for Metal: $error');
      }
      libraries[name] = library;
    }
  }
  file.writeAsBytesSync(
    keepShaderBundleBackends(
      bytes,
      keep,
      metalCompiled: libraries,
      metalSource: sources,
    ),
  );
}

/// Returns the backends that an app for [os] loads. An unknown target keeps
/// Metal and Vulkan.
Set<String> shaderBackendsFor(String? os) => switch (os) {
  'macos' => const {'metal_desktop'},
  'ios' => const {'metal_ios'},
  'linux' || 'windows' || 'android' => const {'vulkan'},
  _ => const {'metal_desktop', 'vulkan'},
};

/// The target OS of the code assets of [input], or null for a build of data
/// assets alone.
String? _targetOS(BuildInput input) {
  final extensions = input.config.json['extensions'];
  final code = extensions is Map ? extensions['code_assets'] : null;
  final os = code is Map ? code['target_os'] : null;
  return os is String ? os : null;
}
