import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_pbr/builder.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

/// A floor of 4 by 4 m and a wall on it, drawn by one node.
GltfDocument _doc() {
  final b = GltfBuilder();
  final pos = b.addFloatAccessor(
    Float32List.fromList([
      0, 0, 0, 0, 0, 4, 4, 0, 4, 4, 0, 0, //
      2, 0, 0, 2, 3, 0, 2, 3, 4, 2, 0, 4,
    ]),
    'VEC3',
    minMax: true,
  );
  final idx = b.addIndexAccessor(
    Uint16List.fromList([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]),
  );
  final mesh = b.addMesh('room', [
    {
      'attributes': {'POSITION': pos},
      'indices': idx,
      'material': b.addMaterial({'name': 'grey', 'doubleSided': true}),
    },
  ]);
  b.setScene([
    b.addNode({'mesh': mesh}),
  ]);
  final glb = readGlb(b.toGlb());
  return GltfDocument(glb.json, [glb.bin]);
}

void main() {
  final doc = _doc();
  final scene = PbrScene('s', GltfModel.read(doc));
  final volume = buildGiVolume([doc], maxCells: 8000, maxProbes: 64);

  List<String> names(FramePlan plan) => [for (final p in plan.passes) p.name];

  test('the sky passes run before the opaque pass without a volume', () {
    final b = PbrBuilder([scene]);
    final plan = b.frame(PbrCamera(), 64, 32);
    final n = names(plan);
    expect(n.indexOf('gi.brdf'), greaterThan(n.indexOf('shadow')));
    expect(n.indexOf('gi.skyIrradiance'), lessThan(n.indexOf('opaque')));
    expect(n, isNot(contains('gi.trace')));
    final opaque = plan.passes[n.indexOf('opaque')] as RenderPassPlan;
    expect(opaque.colors.map((c) => c.target), [
      PbrTargets.hdr,
      GiTargets.gbufferNormal,
      GiTargets.gbufferAlbedo,
    ]);
  });

  test('a volume adds the probe passes and their targets', () {
    final b = PbrBuilder([scene]);
    final plan = b.frame(PbrCamera(), 64, 32);
    b.giVolume = volume;
    final next = b.frame(PbrCamera(), 64, 32);
    expect(identical(next, plan), isFalse);
    final n = names(next);
    expect(n.sublist(n.indexOf('gi.trace'), n.indexOf('gi.trace') + 3), [
      'gi.trace',
      'gi.blend',
      'gi.copy',
    ]);
    final rays = next.targets[GiTargets.giRays]!;
    expect(rays.width, b.settings.gi.raysPerProbe);
    expect(rays.height, volume.activeCount);
    final trace = next.passes[n.indexOf('gi.trace')] as DispatchPlan;
    expect(trace.groups[1], volume.activeCount);
  });

  test('a switch leaves its passes out', () {
    final b = PbrBuilder([scene]);
    final gi = b.settings.gi
      ..ambientOcclusion = false
      ..reflections = false
      ..sky = false;
    final n = names(b.frame(PbrCamera(), 64, 32));
    expect(n, isNot(contains('ao')));
    expect(n, isNot(contains('ssr')));
    expect(n, isNot(contains('history')));
    expect(n, isNot(contains('sky')));
    expect(n, contains('indirect'));
    gi.ambientOcclusion = true;
    expect(names(b.frame(PbrCamera(), 64, 32)), contains('aoBlur'));
  });

  test('the block holds the probe grid and the probes of each frame', () {
    final b = PbrBuilder([scene])..giVolume = volume;
    b.settings.gi.probesPerFrame = 5;
    final plan = b.frame(PbrCamera(), 64, 32);
    final f = plan.frameBlocks[FrameRole('pbr.indirect').block]!.buffer
        .asFloat32List();
    expect(f[IndirectBlock.view], 64);
    expect(f[IndirectBlock.switches + 1], 1);
    expect(f[IndirectBlock.probeOrigin + 3], closeTo(volume.spacing, 1e-6));
    expect(f[IndirectBlock.trace], 0);
    expect(f[IndirectBlock.trace + 1], 5);
    // The first update of a probe replaces its texels.
    expect(f[IndirectBlock.probeParams], 0);
    b.frame(PbrCamera(), 64, 32);
    expect(f[IndirectBlock.trace], 5);
    // A rotation keeps the length of its rows.
    final r = Vector3(
      f[IndirectBlock.rayRotation],
      f[IndirectBlock.rayRotation + 1],
      f[IndirectBlock.rayRotation + 2],
    );
    expect(r.length, closeTo(1, 1e-5));
  });

  test('the sky passes are kept while the sun holds still', () {
    final b = PbrBuilder([scene]);
    final plan = b.frame(PbrCamera(), 64, 32);
    final stamp = plan.retained['gi.sky'];
    expect(stamp, isNot(0));
    expect(plan.retained['gi.skySpecular5'], stamp);
    b.frame(PbrCamera(), 64, 32);
    expect(plan.retained['gi.sky'], stamp);
    b.settings.sunDirection.setValues(0, 1, 0);
    b.frame(PbrCamera(), 64, 32);
    expect(plan.retained['gi.sky'], isNot(stamp));
  });
}
