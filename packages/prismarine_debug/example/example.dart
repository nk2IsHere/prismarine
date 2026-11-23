import 'package:flutter/material.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

/// The groups of the frame graph, bottom to top.
final groups = [
  FrameGroupStyle('game', const Color(0xFF4FC3F7)),
  FrameGroupStyle('render', const Color(0xFFFFB74D)),
];

/// A frame's sample. It sorts each timed section into its group.
class GameSample extends FrameSample {
  GameSample() : super(2);

  @override
  void sort(String section, double v) {
    ms[section.startsWith('render') ? 1 : 0] += v;
  }
}

class GameSamples extends FrameSamples {
  GameSamples() : super(groups);

  @override
  FrameSample newSample() => GameSample();
}

final samples = GameSamples();

/// Times one frame of the game into the graph.
void frame(void Function() update, void Function() render) {
  final f = samples.beginFrame();
  final sw = Stopwatch()..start();
  update();
  f.add('game.update', sw.elapsedMicroseconds / 1000);
  sw.reset();
  render();
  f.add('render.record', sw.elapsedMicroseconds / 1000);
  samples.endFrame(f);
}

/// The debug panel with a header line and one section of your own.
Widget debugPanel(int objects) => DebugPanelShell(
  samples: samples,
  header: (context, p) => [
    Text('${samples.fps.toStringAsFixed(0)} fps', style: p.text.titleSmall),
  ],
  sections: (context, p) => [
    PanelSection(
      'Scene',
      open: p.open,
      children: [Text('$objects objects', style: p.small)],
    ),
  ],
);
