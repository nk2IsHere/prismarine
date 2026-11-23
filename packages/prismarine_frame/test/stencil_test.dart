import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

DrawPlan _draw(int ref, Stencil? stencil) => DrawPlan(
  vertex: 'v',
  pixel: 'p',
  geometry: const ScreenGeometry(3),
  state: DrawState(stencil: stencil),
  viewport: const [0, 0, 1, 1, 0, 1],
  vertexResources: StageResources(),
  pixelResources: StageResources(),
  stencilRef: ref,
);

/// The G-buffer's stencil test. [ORACLE2 ep201 recap, cs_Enter_16 49.277 s]
const _gbuffer = Stencil(passOp: 'replace', readMask: 0, writeMask: 0x7f);

List<int> _held(StencilValues v) => [
  for (final (i, x) in v.held().indexed)
    if (x != 0) i,
];

void main() {
  test('the G-buffer leaves 0, 1 (environment-lit) and 3 (key-lit)', () {
    final v = StencilValues()..reset(0);
    for (final ref in [3, 1, 3, 3, 1]) {
      v.write(_draw(ref, _gbuffer));
    }
    expect(_held(v), [0, 1, 3]);
    expect(v.stale, isTrue);
  });

  test('writes under different masks combine', () {
    final v = StencilValues()
      ..reset(0)
      ..write(_draw(1, const Stencil(passOp: 'replace', writeMask: 1)))
      ..write(_draw(0x82, const Stencil(passOp: 'replace', writeMask: 0x80)));
    expect(_held(v), [0, 1, 0x80, 0x81]);
  });

  test('tests and keeps write nothing; a clear starts over', () {
    final v = StencilValues()
      ..reset(0)
      ..write(_draw(1, const Stencil(func: 'equal', writeMask: 0)))
      ..write(_draw(5, null));
    expect(_held(v), [0]);
    v
      ..write(_draw(3, _gbuffer))
      ..reset(2);
    expect(_held(v), [2]);
  });

  test("a plan's stencil test survives its JSON form", () {
    final plan = FramePlan({}, [
      RenderPassPlan('gbuffer', const [], null, [
        _draw(3, _gbuffer),
        _draw(0, null),
      ]),
    ]);
    final blobs = <String, Uint8List>{};
    var n = 0;
    String put(Uint8List b) {
      final name = 'b${n++}';
      blobs[name] = b;
      return name;
    }

    final json = planToJson(plan, put);
    final back = planFromJson(json, (name) => blobs[name]!);
    final draws = (back.passes.single as RenderPassPlan).draws;
    final st = draws[0].state.stencil!;
    expect(
      [st.func, st.passOp, st.readMask, st.writeMask],
      ['always', 'replace', 0, 0x7f],
    );
    expect(draws[0].stencilRef, 3);
    expect(draws[1].state.stencil, isNull);
  });
}
