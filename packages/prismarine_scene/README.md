# prismarine_scene

prismarine_scene holds scene assets on Flutter. It has a glTF on the GPU with the model of its draws, an asset bundle
that reads files by absolute path and a pace for long loads on the UI isolate. The details are on [the area page](../../docs/areas/scene.md).

## Usage

`GltfModel.read` gives the draws of a glTF with their world matrices and bounds, its materials, cameras and lights,
without Flutter. `GpuScene.load` uploads the buffer views of a glTF that `prepareGltf` of prismarine_assets wrote and
its KTX2 textures on first use.

`FileAssetBundle` reads each key as an absolute file path, off the UI thread. Pass it to a loader that reads textures
through an `AssetBundle`, or to an `AssetImage`. A texture that is not on disk loads as `staticBlackPng`, a 1×1
transparent black PNG. The bundle reports it once through `FileAssetBundle.onMissing`.

`loadPace` lets a long load on the UI isolate give a waiting frame its turn. Call `if (loadPace() case final p?) await
p;` between the steps of the load. It returns null until the load has run for `loadTurn`, 4 ms, since the last turn. The
common case therefore stays synchronous.

## Example

The example loads the textures of a scene by path and gives frames their turn. It is
[`example/example.dart`](example/example.dart):

```dart
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

final textures = FileAssetBundle();

/// Loads the textures of a scene by their absolute paths. The load gives a
/// waiting frame its turn every few milliseconds.
Future<List<ui.Image>> loadTextures(List<String> paths) async {
  final images = <ui.Image>[];
  for (final path in paths) {
    final bytes = await textures.load(path);
    final codec = await ui.instantiateImageCodecFromBuffer(
      await ui.ImmutableBuffer.fromUint8List(bytes.buffer.asUint8List()),
    );
    images.add((await codec.getNextFrame()).image);
    if (loadPace() case final turn?) await turn;
  }
  return images;
}

/// The same bundle serves an image widget.
Image texturePreview(String path) =>
    Image(image: AssetImage(path, bundle: textures));
```

## Platforms

The package runs in Flutter apps on macOS, Linux and Windows.
