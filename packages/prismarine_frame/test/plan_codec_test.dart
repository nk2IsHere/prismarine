import 'dart:convert';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

String _json(FramePlan? p) =>
    p == null ? 'null' : jsonEncode(planToJson(p, base64Encode));

String _drawsJson(List<DrawPlan> draws) => _json(
  FramePlan(const {}, [RenderPassPlan('draws', const [], null, draws)]),
);

/// Returns the plan of [frame] as the builder makes one. The [shared] objects
/// are kept from frame to frame and the per-frame block is made anew.
FramePlan _plan(_Shared shared, int frame) {
  final perFrame = Float32List.fromList([
    frame.toDouble(),
    1,
    2,
    3,
  ]).buffer.asUint8List();
  DrawPlan draw(String label, DrawGeometry g) => DrawPlan(
    vertex: 'vs$label',
    pixel: label == 'b' ? null : 'ps$label',
    geometry: g,
    state: shared.state,
    viewport: [0, 0, 1280, 720, 0, 1],
    vertexResources: StageResources(
      blocks: {'BufferObject': perFrame, 'BufferScene': shared.scene},
      storage: {'out': shared.ref, 'img': const ImageRef('hbao', mip: 1)},
    ),
    pixelResources: StageResources(
      textures: {
        'Sampler_a': shared.file,
        'Sampler_b': const TargetTexture('gbuffer', mips: 3, srgb: true),
        'Sampler_c': shared.constant,
        'Sampler_d': BufferTextureRef(shared.ref),
        'Sampler_e': BufferTexture(shared.scene, 'R32_FLOAT'),
        'Sampler_f': shared.image,
      },
      samplers: {
        0: shared.sampler,
        3: const SamplerState(compare: 'less'),
      },
    ),
    label: label,
    stencilRef: frame,
  );
  return FramePlan(
    {
      'gbuffer': const TargetSpec(1280, 720, 'R8G8B8A8_UNORM', mips: 3),
      'grid': const TargetSpec(16, 8, 'R32_FLOAT', layers: 4, volume: true),
    },
    [
      DispatchPlan(
        'skin',
        'cs1',
        [4, 1, 1],
        StageResources(storage: {'in': InlineBuffer(shared.scene)}),
        indirect: shared.ref,
      ),
      RenderPassPlan(
        'main',
        [
          const Attachment('gbuffer', clear: [0, 0, 0, 1]),
        ],
        const Attachment('depth', clearDepth: 1, clearStencil: 0),
        [draw('a', shared.mesh), draw('b', shared.quad)],
      ),
    ],
    buffers: {'skinned': BufferSpec(64, initial: shared.scene)},
  );
}

class _Shared {
  final scene = Uint8List.fromList(List.generate(40, (i) => i));
  final ref = const BufferRef('skinned', offset: 16, size: 32);
  final file = const FileTexture('obj_tree', srgb: true);
  final constant = ConstantTexture('R8G8B8A8_UNORM', Uint8List(4));
  final image = ConstantTexture(
    'R8G8B8A8_UNORM',
    Uint8List(32),
    width: 4,
    height: 2,
  );
  final sampler = const SamplerState(address: ['clamp', 'wrap', 'mirror']);
  final state = const DrawState(
    blends: [
      Blend(enabled: true, color: ['srcAlpha', 'invSrcAlpha', 'add']),
    ],
    stencil: Stencil(func: 'equal', passOp: 'replace'),
    depthBias: -2,
  );
  late final mesh = DrawMeshGeometry(
    'obj_tree',
    1,
    30,
    600,
    indirect: ref,
    streams: {0: (ref, 12, 'R32G32B32_FLOAT')},
  );
  final quad = InlineGeometry(
    Uint8List(64),
    16,
    const {0: ('R32G32_FLOAT', 0), 1: ('R32G32_FLOAT', 8)},
    4,
    indices: Uint8List(12),
  );
}

void main() {
  test('a read-back buffer crosses with its flag', () {
    final w = PlanWriter(), r = PlanReader();
    for (final read in [true, false, true]) {
      final plan = FramePlan(
        const {},
        const [],
        buffers: {'dust': BufferSpec(16, readBack: read)},
      );
      final back = r.read(w.write(plan)).$1!;
      expect(back.buffers['dust']!.size, 16);
      expect(back.buffers['dust']!.readBack, read);
    }
  });

  test('a target filled from the CPU crosses with its role and bytes', () {
    // A lightmap from the CPU. Its spec refers to a role and each frame gives
    // the bytes.
    final role = FrameRole('lightmap0');
    const spec = TargetSpec(2, 1, 'R8G8B8A8_UNORM', layers: 2);
    final w = PlanWriter(), r = PlanReader();
    for (var frame = 0; frame < 3; frame++) {
      final texels = Uint8List.fromList(List.filled(16, frame));
      final plan = FramePlan(
        {
          'enlightenMap0': TargetSpec(
            spec.width,
            spec.height,
            spec.format,
            layers: 2,
            initial: role.block,
          ),
        },
        const [],
        frameBlocks: {role.block: texels},
      );
      final back = r.read(w.write(plan)).$1!;
      final t = back.targets['enlightenMap0']!;
      expect(t.layers, 2);
      expect(identical(t.initial, role.block), isTrue);
      expect(back.block(t.initial!), texels);
      expect(_json(back), _json(plan));
    }
  });

  test('retained passes cross with their stamps', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    final plan = _plan(shared, 0);
    final first = FramePlan(
      plan.targets,
      plan.passes,
      buffers: plan.buffers,
      frameBlocks: plan.frameBlocks,
      retained: {plan.passes[0].name: 41, plan.passes[1].name: 0},
    );
    expect(r.read(w.write(first, const [])).$1!.retained, first.retained);
    // A plan without retained passes reads back without them.
    expect(r.read(w.write(plan, const [])).$1!.retained, isEmpty);
    expect(r.read(w.write(first, const [])).$1!.retained, first.retained);
  });

  test('plans read back equal, frame after frame', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    for (var f = 0; f < 100; f++) {
      final plan = _plan(shared, f);
      final extra = [(plan.passes[1] as RenderPassPlan).draws.first];
      final (back, draws) = r.read(w.write(plan, extra));
      expect(_json(back), _json(plan));
      expect(_drawsJson(draws), _drawsJson(extra));
    }
    expect(r.read(w.write(null)).$1, isNull);
  });

  test('what the runner keys on stays the same objects', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    List<DrawPlan> draws(FramePlan p) => (p.passes[1] as RenderPassPlan).draws;
    final a = draws(r.read(w.write(_plan(shared, 0))).$1!).first;
    // A copy, since the next read edits the list of the kept pass in place.
    final bs = [...draws(r.read(w.write(_plan(shared, 1))).$1!)];
    final b = bs.first;
    final quad = bs.last.geometry as InlineGeometry;
    expect(
      quad.registers,
      same(
        (draws(r.read(w.write(_plan(shared, 2))).$1!).last.geometry
                as InlineGeometry)
            .registers,
      ),
    );
    expect(
      b.pixelResources.textures['Sampler_c'],
      same(a.pixelResources.textures['Sampler_c']),
    );
    // One block bound by two draws of a frame is one object there too.
    expect(
      bs.last.vertexResources.blocks['BufferObject'],
      same(b.vertexResources.blocks['BufferObject']),
    );
    expect(
      b.pixelResources.textures['Sampler_a'],
      same(a.pixelResources.textures['Sampler_a']),
    );
    expect(b.pixelResources.samplers[0], same(a.pixelResources.samplers[0]));
    expect(
      b.vertexResources.blocks['BufferScene'],
      same(a.vertexResources.blocks['BufferScene']),
    );
    // A block made anew each frame is a new block on the side of the reader
    // too.
    expect(
      b.vertexResources.blocks['BufferObject'],
      isNot(same(a.vertexResources.blocks['BufferObject'])),
    );
  });

  test('a block changed in place is sent again', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    Uint8List scene(FramePlan p) => (p.passes[1] as RenderPassPlan)
        .draws
        .first
        .vertexResources
        .blocks['BufferScene']!;
    final a = scene(r.read(w.write(_plan(shared, 0))).$1!);
    shared.scene[5] = 99;
    final plan = _plan(shared, 1);
    final back = r.read(w.write(plan)).$1!;
    expect(scene(back)[5], 99);
    expect(scene(back), isNot(same(a)));
    expect(_json(back), _json(plan));
  });

  test('a pass made anew over the same draws reads back as one object', () {
    final w = PlanWriter(), r = PlanReader();
    final draw = DrawPlan(
      vertex: 'vs',
      pixel: 'ps',
      geometry: const ScreenGeometry(3),
      state: const DrawState(),
      viewport: [0, 0, 64, 64, 0, 1],
      vertexResources: StageResources(),
      pixelResources: StageResources(),
    );
    FramePlan plan(List<DrawPlan> draws) => FramePlan(const {}, [
      RenderPassPlan(
        'post',
        const [
          Attachment('hdr', clear: [0, 0, 0, 1]),
        ],
        null,
        [...draws],
      ),
    ]);
    RenderPassPlan pass(FramePlan p) => p.passes.single as RenderPassPlan;
    final backs = [
      for (var i = 0; i < 4; i++) pass(r.read(w.write(plan([draw]))).$1!),
    ];
    // The pass is kept from the first frame and is the same object every
    // frame.
    expect(backs[1], same(backs[0]));
    expect(backs[3], same(backs[0]));
    expect(backs[3].draws.single, same(backs[0].draws.single));
    // Another draw list reshapes the kept pass, which stays the same object.
    final version = backs[1].version;
    final other = pass(r.read(w.write(plan([draw, draw]))).$1!);
    expect(other, same(backs[1]));
    expect(other.version, version + 1);
    expect(other.draws, hasLength(2));
    expect(_json(FramePlan(const {}, [other])), _json(plan([draw, draw])));
  });

  test("a role's bytes made anew but the same read back as one object", () {
    final w = PlanWriter(), r = PlanReader();
    final role = FrameRole('test role bytes');
    Uint8List bytes(int v) => Uint8List.fromList([v, 1, 2, 3, 4, 5, 6, 7, 8]);
    Uint8List back(Uint8List b) => r
        .read(
          w.write(FramePlan(const {}, const [], frameBlocks: {role.block: b})),
        )
        .$1!
        .frameBlocks[role.block]!;
    final a = back(bytes(0));
    final again = back(bytes(0));
    expect(again, same(a));
    final changed = back(bytes(9));
    expect(changed, isNot(same(a)));
    expect(changed[0], 9);
    expect(back(bytes(9)), same(changed));
  });

  test('a kept pass with a draw replaced is edited in place', () {
    final w = PlanWriter(), r = PlanReader();
    DrawPlan draw(int v) => DrawPlan(
      vertex: 'vs$v',
      pixel: 'ps',
      geometry: const ScreenGeometry(3),
      state: const DrawState(),
      viewport: [0, 0, 64, 64, 0, 1],
      vertexResources: StageResources(),
      pixelResources: StageResources(),
    );
    final draws = [for (var i = 0; i < 8; i++) draw(i)];
    FramePlan plan(List<DrawPlan> d) => FramePlan(const {}, [
      RenderPassPlan('main', const [Attachment('hdr')], null, [...d]),
    ]);
    RenderPassPlan pass(FramePlan p) => p.passes.single as RenderPassPlan;
    pass(r.read(w.write(plan(draws))).$1!);
    final kept = pass(r.read(w.write(plan(draws))).$1!);
    final version = kept.version;
    final moved = [...draws]..[3] = draw(30);
    final edited = pass(r.read(w.write(plan(moved))).$1!);
    expect(edited, same(kept));
    expect(edited.version, version + 1);
    expect(edited.draws[3].vertex, 'vs30');
    expect(edited.draws[2], same(kept.draws[2]));
    expect(_json(FramePlan(const {}, [edited])), _json(plan(moved)));
    // With most draws changed every draw goes again into the same pass as a
    // reshape.
    final most = [for (var i = 0; i < 8; i++) draw(100 + i)];
    final reshaped = pass(r.read(w.write(plan(most))).$1!);
    expect(reshaped, same(kept));
    expect(reshaped.version, version + 2);
    expect(_json(FramePlan(const {}, [reshaped])), _json(plan(most)));
    // Fewer draws shorten the pass in place.
    final fewer = pass(r.read(w.write(plan(most.sublist(0, 3)))).$1!);
    expect(fewer, same(kept));
    expect(fewer.draws, hasLength(3));
    expect(
      _json(FramePlan(const {}, [fewer])),
      _json(plan(most.sublist(0, 3))),
    );
  });

  test('a string crosses once and reads back as one object', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    final first = w.write(_plan(shared, 0));
    final a = r.read(first).$1!;
    final next = w.write(_plan(shared, 1));
    final b = r.read(next).$1!;
    expect(first.strings, isNotEmpty);
    expect(next.strings, isEmpty);
    String vertex(FramePlan p) =>
        (p.passes[1] as RenderPassPlan).draws.first.vertex;
    expect(vertex(b), same(vertex(a)));
    expect(_json(b), _json(_plan(shared, 1)));
  });

  test('the string tables start again together', () {
    final w = PlanWriter(), r = PlanReader();
    // More distinct strings than the tables hold, the strings of one frame at
    // a time.
    var f = 0;
    for (var n = 0; n < planMaxStrings + 2000; n += 1000, f++) {
      final draws = [
        for (var k = 0; k < 1000; k++)
          DrawPlan(
            vertex: 'vs${n + k}',
            pixel: null,
            geometry: _Shared().quad,
            state: const DrawState(),
            viewport: const [0, 0, 1, 1, 0, 1],
            vertexResources: StageResources(),
            pixelResources: StageResources(),
            label: 'd',
            stencilRef: 0,
          ),
      ];
      final (_, back) = r.read(w.write(null, draws));
      expect(_drawsJson(back), _drawsJson(draws));
    }
  });

  test('unused objects are dropped on both sides and ids reused', () {
    final w = PlanWriter(), r = PlanReader();
    for (var f = 0; f < 10 * planKeep; f++) {
      // A new set of shared objects every frame. None is used again.
      final (back, _) = r.read(w.write(_plan(_Shared(), f)));
      expect(back, isNotNull);
    }
    expect(w.tableSize, lessThan(40 * planKeep));
    expect(r.tableSize, w.tableSize);
    // Still in step after the drops.
    final shared = _Shared();
    for (var f = 0; f < 3; f++) {
      final plan = _plan(shared, f);
      expect(_json(r.read(w.write(plan)).$1), _json(plan));
    }
  });

  // A draw that the builder keeps from frame to frame binds the camera of the
  // frame by role. The plan gives the bytes of the role each frame. The draw
  // crosses by value twice and then by id. It reads back as the same object.
  test('a kept draw crosses once and binds its roles anew', () {
    final role = FrameRole('BufferCamera test');
    final kept = DrawPlan(
      vertex: 'vs',
      pixel: 'ps',
      geometry: const ScreenGeometry(3),
      state: const DrawState(),
      viewport: const [0, 0, 1, 1, 0, 1],
      vertexResources: StageResources(blocks: {'BufferCamera': role.block}),
      pixelResources: StageResources(),
      label: 'kept',
    );
    final w = PlanWriter(), r = PlanReader();
    final backs = <DrawPlan>[];
    for (var f = 0; f < 5; f++) {
      final camera = Uint8List.fromList([f, 1, 2, 3]);
      final plan = FramePlan(
        const {},
        [
          RenderPassPlan('main', const [], null, [kept]),
        ],
        frameBlocks: {role.block: camera},
      );
      final m = w.write(plan);
      final (back, _) = r.read(m);
      expect(_json(back), _json(plan));
      final draw = (back!.passes.single as RenderPassPlan).draws.single;
      expect(back.block(draw.vertexResources.blocks['BufferCamera']!), camera);
      backs.add(draw);
      if (f >= 2) expect(m.ints.length, lessThan(40), reason: 'sent by id');
    }
    // The pass is kept from the first frame and the draw is the same object.
    expect(backs[1], same(backs[0]));
    expect(backs[4], same(backs[0]));
  });

  // A dispatch kept over many frames binds a large block. A new dispatch over
  // the same block refers to it by id, since the reference of the kept
  // dispatch kept the block from the sweep.
  test('a block a kept dispatch names is not swept', () {
    final sources = Uint8List(1 << 16);
    DispatchPlan batch(int groups) => DispatchPlan('skin batch', 'cs', [
      groups,
      1,
      1,
    ], StageResources(storage: {'RawSkinSources': InlineBuffer(sources)}));
    final w = PlanWriter(), r = PlanReader();
    PlanMessage send(DispatchPlan d) {
      final plan = FramePlan(const {}, [d]);
      final m = w.write(plan);
      expect(_json(r.read(m).$1), _json(plan));
      return m;
    }

    final kept = batch(4);
    for (var f = 0; f < 3 * planKeepBlocks; f++) {
      send(kept);
    }
    final m = send(batch(5));
    expect(m.bytes, isEmpty, reason: 'the sources by id');
  });

  test('a pass\'s rows cross when they change, and are kept between', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    final base = (_plan(shared, 0).passes[1] as RenderPassPlan).draws;
    final a = base.first, b = base.last;
    final c = (_plan(shared, 1).passes[1] as RenderPassPlan).draws.first;
    FramePlan plan(List<int> ids, List<DrawPlan> rows) => FramePlan(const {}, [
      RenderPassPlan('gbuffer', const [], null, [])..rows = RowSet(ids, rows),
    ]);
    RowSet rowsOf((FramePlan?, List<DrawPlan>) m) =>
        (m.$1!.passes.single as RenderPassPlan).rows!;
    final first = rowsOf(r.read(w.write(plan([1, 2], [a, b]))));
    expect(first.ids, [1, 2]);
    expect(_drawsJson(first.plans), _drawsJson([a, b]));
    // Nothing changed. No draw crosses and the set of the reader is the same.
    final m = w.write(plan([1, 2], [a, b]));
    expect(m.ints.length, lessThan(40));
    expect(rowsOf(r.read(m)), same(first));
    // Row 1 changed, row 2 is gone and row 3 is new.
    final next = rowsOf(r.read(w.write(plan([1, 3], [c, b]))));
    expect(next.ids, [1, 3]);
    expect(_drawsJson(next.plans), _drawsJson([c, b]));
    // A new writer starts the reader's table afresh.
    final fresh = rowsOf(r.read(PlanWriter().write(plan([4], [a]))));
    expect(fresh.ids, [4]);
  });

  test('a pass with rows stays one object as its rows change', () {
    final shared = _Shared();
    final w = PlanWriter(), r = PlanReader();
    final base = (_plan(shared, 0).passes[1] as RenderPassPlan).draws;
    final a = base.first, b = base.last;
    FramePlan plan(List<int> ids, List<DrawPlan> rows, double p) =>
        FramePlan(const {}, [
          RenderPassPlan('cascadeShadows', const [], null, [b])
            ..rows = RowSet(ids, rows, params: Float32List.fromList([p])),
        ]);
    RenderPassPlan passOf((FramePlan?, List<DrawPlan>) m) =>
        m.$1!.passes.single as RenderPassPlan;
    final first = passOf(r.read(w.write(plan([1], [a], 1))));
    final v = first.version;
    // New culling values each frame give the same pass with a new version.
    final next = passOf(r.read(w.write(plan([1], [a], 2))));
    expect(next, same(first));
    expect(next.version, greaterThan(v));
    expect(next.rows!.params, [2]);
    expect(_drawsJson(next.allDraws), _drawsJson([a, b]));
    // An added row gives the same pass with the draws of the row.
    final third = passOf(r.read(w.write(plan([1, 2], [a, b], 2))));
    expect(third, same(first));
    expect(_drawsJson(third.allDraws), _drawsJson([a, b, b]));
  });
}
