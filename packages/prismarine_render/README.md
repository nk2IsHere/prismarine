# prismarine_render

prismarine_render records the frame plans of [prismarine_frame](../prismarine_frame/README.md) on Flutter GPU. A
`FrameRunner` creates the targets and buffers of a plan and records each pass on one command buffer. It keeps what stays
the same from frame to frame, such as the pipeline and the bindings of a draw and the passes whose retained stamp did
not change. The details are on [the area page](../../docs/areas/render.md).

## Usage

The runner asks a `RenderAssets` of your app for everything that a plan gives by string. These are shaders by id with
their `ShaderRecord`, textures by stem and meshes by stem as a `RenderMesh`. Your implementation loads them on first use
and keeps them until a `release` after a scene closed. `RunnerShaders` gives the ids of the shaders that the runner
draws with besides the shaders of a plan.

`FrameRunner.run` records a plan, submits it and completes when the GPU is done. With `present`, the frame ends with a
copy of that target into one of three textures. `presented` holds the copy of the last finished frame, which a widget
can show through `asImage`.

The package needs the flutter_gpu of the patched engine. Its pubspec takes it from `third_party/flutter_gpu` through
`dependency_overrides`. Your app does the same.

## Example

The example records a plan each frame and returns the picture. A plan that only clears its colour target needs no
assets. It is [`example/example.dart`](example/example.dart):

```dart
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_render/prismarine_render.dart';

/// The shaders of the runner itself, by their ids in your shader library.
const runnerShaders = RunnerShaders(
  nullPixel: 'Runner/null.frag',
  depthClampPixel: 'Runner/depth_clamp.frag',
  stencilCopyVertex: 'Runner/stencil_copy.vert',
  stencilCopyPixel: 'Runner/stencil_copy.frag',
);

/// Records one frame plan a frame and returns the picture for a widget.
/// [assets] is your implementation, which loads the shaders, textures and
/// meshes that the plans give by name.
class Renderer {
  Renderer(RenderAssets assets)
    : runner = FrameRunner(assets, runnerShaders)..warn = debugPrint;

  final FrameRunner runner;

  Future<ui.Image?> draw(FramePlan plan) async {
    if (!await runner.run(plan, present: 'color')) return null;
    return runner.presented?.asImage();
  }
}

/// A frame that clears its colour target to a dark blue.
FramePlan clearFrame(int width, int height) => FramePlan(
  {'color': TargetSpec(width, height, 'R8G8B8A8_UNORM')},
  [
    RenderPassPlan(
      'clear',
      [
        const Attachment('color', clear: [0.05, 0.1, 0.2, 1]),
      ],
      null,
      const [],
    ),
  ],
);
```

## Platforms

The package runs in Flutter apps on macOS with Metal and on Linux and Windows with Vulkan. The runner needs the patched
engine for the features that stock Flutter GPU lacks, such as compute and texture arrays.
