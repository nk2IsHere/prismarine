import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

/// Two groups: `cpu.*` sections go to the first, `gpu.*` to the second.
class _Sample extends FrameSample {
  _Sample() : super(2);

  @override
  void sort(String section, double v) {
    if (section.startsWith('cpu.')) ms[0] += v;
    if (section.startsWith('gpu.')) ms[1] += v;
  }
}

class _Samples extends FrameSamples {
  _Samples()
    : super([
        FrameGroupStyle('cpu', const Color(0xFF2980B9)),
        FrameGroupStyle('gpu', const Color(0xFFF1C40F)),
      ]);

  @override
  FrameSample newSample() => _Sample();
}

void main() {
  test('sections go to their groups and stay listed in order', () {
    final d = _Samples();
    final f = d.beginFrame()
      ..add('cpu.input', 1.5)
      ..add('gpu.shadows', 2)
      ..add('cpu.input', 0.5)
      ..add('count.draws', 40);
    d.endFrame(f, raster: 3);
    final s = d.frames.single;
    expect(s.ms, [2.0, 2.0]);
    expect(s.total, 7);
    expect(
      [for (var i = 0; i < s.sectionCount; i++) s.sectionNames[i]],
      ['cpu.input', 'gpu.shadows', 'cpu.input', 'count.draws'],
    );
  });

  test('an open frame takes sections until the next frame starts', () {
    final d = _Samples();
    var bumps = 0;
    d.graph.addListener(() => bumps++);
    final f = d.beginFrame()..add('cpu.tick', 1);
    d.endFrame(f, keepOpen: true);
    expect(d.frames, isEmpty);
    d.openFrame!.add('gpu.paint', 2);
    d.beginFrame();
    expect(d.frames.single.ms, [1.0, 2.0]);
    expect(d.frames.single.gap, greaterThanOrEqualTo(0));
    expect(bumps, 1);
  });

  test('the ring keeps the last 240 frames; means are over the last 60', () {
    final d = _Samples();
    for (var i = 0; i < 300; i++) {
      d.endFrame(
        d.beginFrame()
          ..dt = 1 / 50
          ..add('cpu.tick', i < 240 ? 0 : 3),
        raster: 1,
      );
    }
    expect(d.frames, hasLength(240));
    expect(d.meanMs(0), 3);
    expect(d.meanMs(1), 0);
    expect(d.meanRaster, 1);
    expect(d.fps, closeTo(50, 1e-9));
  });
}
