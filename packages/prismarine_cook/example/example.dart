import 'dart:io';

import 'package:prismarine_cook/prismarine_cook.dart';

/// Cooks the shaders of the app in the current folder with the impellerc of
/// its engine release.
Future<void> main() async {
  final app = Project.find(Directory.current.path);
  final project = app == null ? null : Project.load(app);
  if (project == null) {
    print('No prismarine.yaml in this folder or above it.');
    return;
  }
  final impellerc = hookImpellerc(project.dir, Platform.environment);
  for (final entry in project.shaders) {
    final c = await cookShaders(
      project,
      entry,
      impellerc: impellerc,
      cacheDir: shaderCacheDir(Platform.environment),
    );
    print('${entry.id}: ${c.current ? 'current' : '${c.shaders} cooked'}');
  }
}
