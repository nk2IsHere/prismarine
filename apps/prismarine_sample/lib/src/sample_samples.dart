import 'package:flutter/widgets.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

/// The groups of the frame graph of the sample.
/// The GPU groups are the timed parts of the frame, or `gpu` for the whole
/// GPU time when the frame is not split.
enum SampleGroup {
  step('step', Color(0xFF7FB3D5)),
  build('build', Color(0xFF82E0AA)),
  record('record', Color(0xFFF7DC6F)),
  gpu('gpu', Color(0xFFEB984E)),
  shadows('gpu shadows', Color(0xFF5D6D7E)),
  pointShadows('gpu point shadows', Color(0xFF85929E)),
  scene('gpu scene', Color(0xFFDC7633)),
  fog('gpu fog', Color(0xFF48C9B0)),
  taa('gpu taa', Color(0xFFF1948A)),
  bloom('gpu exposure and bloom', Color(0xFFF4D03F)),
  toneMap('gpu tone map', Color(0xFFAF7AC5)),
  ui('ui other', Color(0xFFBB8FCE));

  const SampleGroup(this.label, this.color);
  final String label;
  final Color color;

  /// Returns the group of the section [label], or null for none.
  static SampleGroup? of(String label) => _byLabel[label];
  static final _byLabel = {for (final g in values) g.label: g};

  /// True for the groups of GPU time, which runs beside the tick.
  bool get isGpu => label.startsWith('gpu');
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
    // A part of another renderer without a group of its own counts as gpu.
    final g =
        SampleGroup.of(section) ??
        (section.startsWith('gpu') ? SampleGroup.gpu : null);
    if (g == null || g == SampleGroup.ui) return;
    ms[g.index] += v;
    // The GPU time runs beside the tick, the rest inside it.
    if (!g.isGpu) _timed += v;
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
