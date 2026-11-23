import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'frame_samples.dart';
import 'profiler.dart' show UiWork;

/// The frame graph's legend: each group's colour and its mean ms over the
/// last 60 frames, then the raster's.
Widget frameGraphLegend(FrameSamples d, TextStyle small) => Wrap(
  spacing: 8,
  children: [
    for (var g = 0; g < d.groups.length; g++)
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, color: d.groups[g].color),
          const SizedBox(width: 3),
          Text(
            '${d.groups[g].label} ${d.meanMs(g).toStringAsFixed(1)}',
            style: small,
          ),
        ],
      ),
    Text('raster ${d.meanRaster.toStringAsFixed(1)} ms', style: small),
  ],
);

/// Stacked time per group plus raster (translucent white) for the last 240
/// frames, a tick at each frame's wall gap, lines at 16.7 and 33.3 ms. It
/// repaints every frame on [FrameSamples.graph] (the rest of the panel
/// rebuilds at most every 250 ms); hovering a bar lists that frame's
/// sections.
class FrameGraph extends StatefulWidget {
  const FrameGraph(this.state, {super.key, this.style});
  final FrameSamples state;
  final TextStyle? style;

  @override
  State<FrameGraph> createState() => _FrameGraphState();
}

class _FrameGraphState extends State<FrameGraph> {
  /// The frame under the pointer.
  final _hover = ValueNotifier<FrameSample?>(null);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  void _pick(Offset at, double width) {
    final frames = widget.state.frames;
    final i = frames.length - 1 - ((width - at.dx) / (width / 240)).floor();
    _hover.value = i >= 0 && i < frames.length ? frames.elementAt(i) : null;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 90,
        child: LayoutBuilder(
          builder: (_, c) => MouseRegion(
            onHover: (e) => _pick(e.localPosition, c.maxWidth),
            onExit: (_) => _hover.value = null,
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _GraphPainter(widget.state, _hover),
              ),
            ),
          ),
        ),
      ),
      ValueListenableBuilder(
        valueListenable: _hover,
        builder: (_, f, _) => f == null
            ? const SizedBox.shrink()
            : SelectableText(
                _hoverText(f, widget.state.groups),
                style: widget.style,
              ),
      ),
    ],
  );
}

/// A frame's groups (largest first), its gap and raster, then its sections
/// in the order they came.
String _hoverText(FrameSample f, List<FrameGroupStyle> groups) {
  String n(double v) => v.toStringAsFixed(v >= 10 ? 1 : 2);
  final shown = [
    for (var g = 0; g < groups.length; g++)
      if (f.ms[g].abs() >= 0.005) (groups[g], f.ms[g]),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final sections = <String, double>{};
  for (var i = 0; i < f.sectionCount; i++) {
    final k = f.sectionNames[i], v = f.sectionMs[i];
    if (k.startsWith('draws.') || k.startsWith('count.')) continue;
    sections[k] = (sections[k] ?? 0) + v;
  }
  return 'gap ${n(f.gap)} · tick ${n(f.tick)} · raster ${n(f.raster)} ms\n'
      '${[for (final (g, v) in shown) '${g.label} ${n(v)}'].join(' · ')}\n'
      '${[for (final MapEntry(:key, :value) in sections.entries)
        if (value >= 0.05) '$key ${n(value)}'].join(' · ')}';
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.state, this.hover)
    : super(repaint: Listenable.merge([state.graph, hover]));
  final FrameSamples state;
  final ValueNotifier<FrameSample?> hover;

  static final _raster = Paint()..color = const Color(0x80FFFFFF);
  static final _back = Paint()..color = const Color(0xFF0E0F12);
  static final _gapTick = Paint()..color = const Color(0xFFFFFFFF);
  static final _line = Paint()
    ..color = const Color(0x60FFFFFF)
    ..strokeWidth = 1;
  static final _hoverPaint = Paint()
    ..color = const Color(0x40FFFFFF)
    ..style = PaintingStyle.fill;
  final _sw = Stopwatch();

  @override
  void paint(Canvas canvas, Size size) {
    _sw
      ..reset()
      ..start();
    canvas.drawRect(Offset.zero & size, _back);
    const maxMs = 50.0;
    double y(double ms) => size.height * (1 - math.min(ms, maxMs) / maxMs);
    final w = size.width / 240;
    final groups = state.groups;
    final paths = [for (final _ in groups) Path()];
    final raster = Path(), gaps = Path();
    final frames = state.frames;
    final hovered = hover.value;
    var i = 0;
    for (final f in frames) {
      final x = size.width - (frames.length - i) * w;
      i++;
      if (identical(f, hovered)) {
        canvas.drawRect(Rect.fromLTRB(x, 0, x + w, size.height), _hoverPaint);
      }
      var acc = 0.0;
      for (var g = 0; g < groups.length; g++) {
        final ms = f.ms[g];
        if (ms <= 0) continue;
        paths[g].addRect(Rect.fromLTRB(x, y(acc + ms), x + w, y(acc)));
        acc += ms;
      }
      if (f.raster > 0) {
        raster.addRect(Rect.fromLTRB(x, y(acc + f.raster), x + w, y(acc)));
      }
      if (f.gap > 0) {
        final gy = y(f.gap);
        gaps.addRect(Rect.fromLTRB(x, gy, x + w, gy + 1));
      }
    }
    for (var g = 0; g < groups.length; g++) {
      canvas.drawPath(paths[g], groups[g].paint);
    }
    canvas.drawPath(raster, _raster);
    canvas.drawPath(gaps, _gapTick);
    for (final ms in [1000 / 60, 1000 / 30]) {
      canvas.drawLine(Offset(0, y(ms)), Offset(size.width, y(ms)), _line);
    }
    // The graph's own cost, in a profile while the panel shows.
    final ms = _sw.elapsedMicroseconds / 1000;
    UiWork.add(ms, paint: true);
    state.profiler?.add('panel.graph', ms);
    state.openFrame?.add('panel.graph', ms);
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      !identical(old.state, state) || !identical(old.hover, hover);
}
