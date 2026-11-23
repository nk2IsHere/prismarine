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
