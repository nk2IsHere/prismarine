import 'package:flutter/widgets.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

/// The groups of the frame graph of the sample.
enum SampleGroup {
  step('step', Color(0xFF7FB3D5)),
  build('build', Color(0xFF82E0AA)),
  record('record', Color(0xFFF7DC6F)),
  gpu('gpu', Color(0xFFEB984E)),
  ui('ui other', Color(0xFFBB8FCE));

  const SampleGroup(this.label, this.color);
  final String label;
  final Color color;
}

/// A frame of the sample with its sections put into [SampleGroup]s.
class SampleFrame extends FrameSample {
  SampleFrame() : super(SampleGroup.values.length);

  double _timed = 0;

  @override
  void reset() {
    super.reset();
    _timed = 0;
  }

  @override
  void sort(String section, double v) {
    final g = switch (section) {
      'step' => SampleGroup.step,
      'build' => SampleGroup.build,
      'record' => SampleGroup.record,
      'gpu' => SampleGroup.gpu,
      _ => null,
    };
    if (g == null) return;
    ms[g.index] += v;
    // The GPU time runs beside the tick, the rest inside it.
    if (g != SampleGroup.gpu) _timed += v;
  }

  @override
  void finish({
    required double gap,
    required double untimed,
    bool inline = false,
  }) {
    super.finish(gap: gap, untimed: untimed, inline: inline);
    if (tick > _timed) ms[SampleGroup.ui.index] += tick - _timed;
  }
}

/// The frame samples of the sample for its frame graph.
class SampleSamples extends FrameSamples {
  SampleSamples()
    : super([
        for (final g in SampleGroup.values) FrameGroupStyle(g.label, g.color),
      ]);

  @override
  SampleFrame newSample() => SampleFrame();
}
