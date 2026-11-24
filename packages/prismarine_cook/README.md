# prismarine_cook

prismarine_cook prepares what an app needs before it is built, as its `prismarine.yaml` lists. It compiles the
shaders with the impellerc of the patched engine and runs the asset steps, such as the download of a scene. A step
runs again only when its inputs changed. With `cookHook` in the build hook of the app, a plain `flutter build` also
compiles the shaders. The details are on [the area page](../../docs/areas/cook.md).

## Usage

An app depends on prismarine_cook and `hooks` and calls `cookHook` from `hook/build.dart`.

```dart
import 'package:hooks/hooks.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

void main(List<String> args) async {
  await build(args, cookHook);
}
```

`Project.load` reads the project file of an app. `cookShaders` and `cookAsset` cook one entry or step and return
whether it was current. `findEngine` finds the engine of an `EngineRelease` in an engine folder. The keys of
`prismarine.yaml` are on [the build page](../../docs/building.md#your-own-app).

## Example

The example cooks the shaders of the app in the current folder. It is [`example/example.dart`](example/example.dart):

```dart
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
```

## Platforms

The package is pure Dart and runs on macOS, Linux and Windows.
