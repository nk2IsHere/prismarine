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
