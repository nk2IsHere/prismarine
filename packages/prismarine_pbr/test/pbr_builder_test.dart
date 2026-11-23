import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_pbr/builder.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

/// One triangle mesh drawn by three nodes along x from [offset] with an
/// opaque, a masked and a blended material.
GltfModel _model([double offset = 0]) {
  final b = GltfBuilder();
  final pos = b.addFloatAccessor(
    Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
    'VEC3',
    minMax: true,
  );
  final idx = b.addIndexAccessor(Uint16List.fromList([0, 1, 2]));
  final meshes = [
    for (final mode in ['OPAQUE', 'MASK', 'BLEND'])
      b.addMesh(mode, [
        {
          'attributes': {'POSITION': pos},
          'indices': idx,
          'material': b.addMaterial({'name': mode, 'alphaMode': mode}),
        },
      ]),
  ];
  final nodes = [
    for (final (i, m) in meshes.indexed)
      b.addNode({
        'mesh': m,
        'translation': [offset + i * 10.0, 0, 0],
      }),
  ];
  b.setScene(nodes);
  final glb = readGlb(b.toGlb());
  return GltfModel.read(GltfDocument(glb.json, [glb.bin]));
}

const _scenePasses = ['shadow', 'pointShadows', 'opaque', 'blend', 'markers'];

void main() {
  final scene = PbrScene('s', _model());

  test('the plan has its passes and each draw in its pass', () {
    final b = PbrBuilder([scene]);
    final plan = b.frame(PbrCamera(), 64, 32);
    final passes = {
      for (final p in plan.passes.whereType<RenderPassPlan>()) p.name: p.draws,
    };
    expect(passes.keys.take(5), [
      'shadow',
      'pointShadows',
      'opaque',
      'blend',
      'markers',
    ]);
    expect(passes.keys.last, 'tonemap');
    expect(passes['shadow']!.map((d) => d.label), ['OPAQUE', 'MASK']);
    expect(passes['opaque']!.map((d) => d.pixel), [
      PbrShaderIds.litPixel,
      PbrShaderIds.litMaskedPixel,
    ]);
    expect(passes['blend']!.single.label, 'BLEND');
    // glTF's counter-clockwise fronts are clockwise on the render target.
    expect(passes['opaque']!.first.state.frontCounterClockwise, isFalse);
    expect(passes['opaque']!.first.state.cull, 'back');
    expect(plan.targets[PbrTargets.hdr]!.width, 64);
    expect(
      (passes['opaque']!.first.geometry as DrawMeshGeometry).mesh,
      's:0:0',
    );
  });

  test('a frame keeps the plan and writes the frame role', () {
    final b = PbrBuilder([scene]);
    final cam = PbrCamera()..position.setValues(1, 2, 3);
    final plan = b.frame(cam, 64, 32);
    b.lights.add(PointLight()..position.setValues(4, 5, 6));
    expect(identical(b.frame(cam, 64, 32), plan), isTrue);
    final role = FrameRole('pbr.frame').block;
    final f = plan.frameBlocks[role]!.buffer.asFloat32List();
    expect(f.sublist(32, 35), [1, 2, 3]);
    // The count of point lights and the first light.
    expect(f[51], 1);
    expect(f.sublist(56, 59), [4, 5, 6]);
    // The projection scale, the radius and the switch of the markers.
    expect(f[186], closeTo(0.2, 1e-6));
    expect(f[187], 1);
    expect(f[184], greaterThan(0));
    expect(identical(b.frame(cam, 128, 32), plan), isFalse);
  });

  test('blended draws go from back to front', () {
    final two = PbrScene('t', _model(50));
    final b = PbrBuilder([scene, two]);
    final cam = PbrCamera();
    final blend = b
        .frame(cam..position.setValues(-100, 0, 0), 64, 32)
        .passes
        .cast<RenderPassPlan>()
        .firstWhere((p) => p.name == 'blend');
    expect(blend.draws, hasLength(2));
    final far = blend.draws.first;
    b.frame(cam..position.setValues(100, 0, 0), 64, 32);
    expect(identical(blend.draws.last, far), isTrue);
  });

  test('the shadow pass is kept while the sun holds still', () {
    final b = PbrBuilder([scene]);
    final plan = b.frame(PbrCamera(), 64, 32);
    final stamp = plan.retained['shadow'];
    b.frame(PbrCamera(), 64, 32);
    expect(plan.retained['shadow'], stamp);
    b.settings.sunDirection.setValues(0, 1, 0);
    b.frame(PbrCamera(), 64, 32);
    expect(plan.retained['shadow'], isNot(stamp));
  });

  test('the post passes follow the switches of the settings', () {
    final b = PbrBuilder([scene]);
    List<String> names() => [
      for (final p in b.frame(PbrCamera(), 64, 32).passes)
        if (!_scenePasses.contains(p.name)) p.name,
    ];
    b.settings.volume.enabled = false;
    final post = b.settings.post..bloomQuality = PbrQuality.low;
    expect(names(), [
      'taa',
      'exposureHistogram',
      'exposureAdapt',
      for (var i = 0; i < 5; i++) 'bloomDown$i',
      for (var i = 3; i >= 0; i--) 'bloomUp$i',
      'tonemap',
    ]);
    expect(b.timedPasses, [
      'pointShadows',
      'opaque',
      'taa',
      'exposureHistogram',
      'tonemap',
    ]);
    expect(b.partLabels, hasLength(b.timedPasses.length + 1));
    post
      ..taa = false
      ..bloom = false
      ..autoExposure = false;
    expect(names(), ['tonemap']);
    final tonemap = b.frame(PbrCamera(), 64, 32).passes.last as RenderPassPlan;
    expect(tonemap.colors.map((c) => c.target), [PbrTargets.backbuffer]);
    post.taa = true;
    final withTaa = b.frame(PbrCamera(), 64, 32).passes.last as RenderPassPlan;
    expect(withTaa.colors.map((c) => c.target), [
      PbrTargets.backbuffer,
      PbrPostTargets.taaHistory,
    ]);
  });

  test('the camera moves by a sub-pixel jitter with TAA', () {
    final b = PbrBuilder([scene]);
    final cam = PbrCamera();
    final seen = <double>{};
    for (var i = 0; i < 8; i++) {
      b.frame(cam, 64, 32);
      expect(b.jitter.x.abs(), lessThan(0.5));
      expect(b.jitter.y.abs(), lessThan(0.5));
      seen.add(b.jitter.x);
    }
    expect(seen, hasLength(8));
    b.settings.post.taa = false;
    b.frame(cam, 64, 32);
    expect(b.jitter.x, 0);
  });

  test('the fog adds its computes and its pass after the markers', () {
    final b = PbrBuilder([scene]);
    final plan = b.frame(PbrCamera(), 64, 32);
    final names = [for (final p in plan.passes) p.name];
    final at = names.indexOf('markers');
    expect(names.sublist(at + 1, at + 4), [
      'volumeInject',
      'volumeIntegrate',
      'volumeApply',
    ]);
    expect(plan.targets[PbrVolumeTargets.scatter]!.volume, isTrue);
    expect(b.timedPasses, contains('volumeInject'));
    b.settings.volume.enabled = false;
    expect(
      b.frame(PbrCamera(), 64, 32).passes.map((p) => p.name),
      isNot(contains('volumeInject')),
    );
  });

  test('point lights near the camera get the shadow slots', () {
    final b = PbrBuilder([scene])..settings.pointShadows.budget = 1;
    final cam = PbrCamera();
    // The camera looks along negative z from the origin.
    final near = PointLight()
      ..position.setValues(1, 0, -3)
      ..range = 20;
    final far = PointLight()
      ..position.setValues(1, 0, -15)
      ..range = 20;
    b.lights.addAll([far, near]);
    final plan = b.frame(cam, 64, 32);
    final f = plan.frameBlocks[FrameRole('pbr.frame').block]!.buffer
        .asFloat32List();
    // The shadow slot plus one of each light, in the w of its colour.
    expect(f[123], 0);
    expect(f[127], 1);
    final pass =
        plan.passes.firstWhere((p) => p.name == 'pointShadows')
            as RenderPassPlan;
    // The opaque and the masked triangle are within the range. Each is seen
    // by the faces whose frustum its sphere touches.
    expect(pass.draws, isNotEmpty);
    expect(pass.draws.map((d) => d.label).toSet(), {'OPAQUE', 'MASK'});
    final stamp = plan.retained['pointShadows'];
    b.frame(cam, 64, 32);
    expect(plan.retained['pointShadows'], stamp);
    near.position.x = 2;
    b.frame(cam, 64, 32);
    expect(plan.retained['pointShadows'], isNot(stamp));
    // A light behind a wall of distance is out of the budget and keeps no
    // slot. A light out of the view gets none.
    near.position.setValues(0, 0, 50);
    b.frame(cam, 64, 32);
    expect(f[123], 1);
    expect(f[127], 0);
  });

  test('lookAlong matches the view matrix of vector_math', () {
    final a = Matrix4.zero(), b = Matrix4.zero();
    final eye = Vector3(1, 2, 3), fwd = Vector3(0.3, -0.2, -1);
    lookAlong(a, eye, fwd, Vector3(0, 1, 0));
    setViewMatrix(b, eye, eye + fwd, Vector3(0, 1, 0));
    for (var i = 0; i < 16; i++) {
      expect(a.storage[i], closeTo(b.storage[i], 1e-9));
    }
  });
}
