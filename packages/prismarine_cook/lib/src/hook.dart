import 'dart:io';

import 'package:hooks/hooks.dart';

import 'engine.dart';
import 'hashing.dart';
import 'host.dart';
import 'project.dart';
import 'shader_cook.dart';

/// Cooks the shaders of the app whose inputs changed and declares those
/// inputs as dependencies of the build hook. An app without a
/// `prismarine.yaml` cooks nothing.
///
/// ```dart
/// void main(List<String> args) => build(args, cookHook);
/// ```
Future<void> cookHook(BuildInput input, BuildOutputBuilder output) async {
  final dir = input.packageRoot.toFilePath();
  final app = dir.endsWith('/') || dir.endsWith(r'\')
      ? dir.substring(0, dir.length - 1)
      : dir;
  final project = Project.load(app);
  if (project == null) return;
  output.dependencies.add(File('$app/prismarine.yaml').uri);
  if (project.shaders.isEmpty) return;
  final impellerc = hookImpellerc(app, Platform.environment);
  output.dependencies.add(File(impellerc).uri);
  final choice = File(EngineChoice.pathIn(app));
  if (choice.existsSync()) output.dependencies.add(choice.uri);
  for (final entry in project.shaders) {
    await cookShaders(
      project,
      entry,
      impellerc: impellerc,
      cacheDir: shaderCacheDir(Platform.environment),
    );
    for (final source in entry.sources(project)) {
      if (FileSystemEntity.isDirectorySync(source)) {
        output.dependencies.add(Directory(source).uri);
      }
      for (final f in filesUnder([source])) {
        output.dependencies.add(f.uri);
      }
    }
    output.dependencies.add(File(shaderStamp(project, entry).path).uri);
  }
}

/// Returns the impellerc for the build hook of the app in [appDir]. It is the
/// impellerc that the last prismarine command recorded in the app, else the
/// one of the fetched engine of its release in the engine folder that [env]
/// sets. Throws a [StateError] with the fix when neither exists.
String hookImpellerc(String appDir, Map<String, String> env) {
  final choice = EngineChoice.readIn(appDir);
  if (choice != null && File(choice.impellerc).existsSync()) {
    return choice.impellerc;
  }
  final releaseFile = releaseFileOfApp(appDir);
  final target = hostTarget();
  if (target == null) {
    throw StateError('prismarine has no engine for this OS and CPU.');
  }
  if (releaseFile == null) {
    throw StateError(
      'The app does not resolve the flutter_gpu of prismarine. Run '
      '`prismarine build` in $appDir.',
    );
  }
  final release = EngineRelease.read(releaseFile);
  final search = findEngine(engineDir(env), target, release);
  final engine = search.engine;
  if (engine == null || !File(engine.impellerc).existsSync()) {
    throw StateError(
      'The shaders need the engine ${release.tag}, which is not in '
      '${search.dir}. Run `prismarine engine`.',
    );
  }
  return engine.impellerc;
}
