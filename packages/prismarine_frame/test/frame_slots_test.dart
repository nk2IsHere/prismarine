import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

final _draw = DrawPlan(
  vertex: 'v',
  pixel: 'p',
  geometry: const ScreenGeometry(3),
  state: const DrawState(),
  viewport: const [0, 0, 1, 1, 0, 1],
  vertexResources: StageResources(),
  pixelResources: StageResources(),
);

RenderPassPlan _frame(FrameSlots s, String second) {
  final roles = s.begin();
  s
      .pass('main', [const Attachment('hdr'), Attachment(second)], null)
      .draws
      .add(_draw);
  return s.publish(roles).passes.single as RenderPassPlan;
}

void main() {
  // The main pass writes its glow mask over the G-buffer until motion blur
  // reads the G-buffer's motion vectors, and into a target of its own
  // then; its draws are the same kept draws on both frames.
  test('a pass whose targets change with the same draws publishes anew', () {
    final s = FrameSlots();
    final a = _frame(s, 'gbuffer');
    expect(identical(_frame(s, 'gbuffer'), a), isTrue);
    final b = _frame(s, 'glowMask');
    expect(b.colors[1].target, 'glowMask');
    expect(_frame(s, 'gbuffer').colors[1].target, 'gbuffer');
  });
}
