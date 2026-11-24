import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_scene/model.dart';

/// A triangle under a node that moves it by (10, 0, 0) and scales it by 2,
/// a camera, a point light and a masked material.
GltfDocument _doc() {
  final b = GltfBuilder();
  final pos = b.addFloatAccessor(
    Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
    'VEC3',
    minMax: true,
  );
  final idx = b.addIndexAccessor(Uint16List.fromList([0, 1, 2]));
  final mat = b.addMaterial({
    'alphaMode': 'MASK',
    'alphaCutoff': 0.3,
    'doubleSided': true,
    'pbrMetallicRoughness': {'metallicFactor': 0.25},
  });
  final mesh = b.addMesh('tri', [
    {
      'attributes': {'POSITION': pos},
      'indices': idx,
      'material': mat,
    },
  ]);
  b.json['cameras'] = [
    {
      'type': 'perspective',
      'perspective': {'yfov': 0.8, 'znear': 0.1},
    },
  ];
  b.json['extensions'] = {
    'KHR_lights_punctual': {
      'lights': [
        {
          'type': 'point',
          'color': [1, 0.5, 0],
          'intensity': 3,
          'range': 4,
        },
      ],
    },
  };
  final child = b.addNode({'mesh': mesh});
  final cam = b.addNode({
    'camera': 0,
    'translation': [0, 1, 5],
  });
  final light = b.addNode({
    'translation': [0, 2, 0],
    'extensions': {
      'KHR_lights_punctual': {'light': 0},
    },
  });
  final root = b.addNode({
    'translation': [10, 0, 0],
    'scale': [2, 2, 2],
    'children': [child],
  });
  b.setScene([root, cam, light]);
  final glb = readGlb(b.toGlb());
  return GltfDocument(glb.json, [glb.bin]);
}

void main() {
  test('draws carry their world matrix and bounds', () {
    final m = GltfModel.read(_doc());
    expect(m.draws, hasLength(1));
    final d = m.draws.single;
    expect(d.world.getTranslation().x, 10);
    expect(d.center.x, closeTo(11, 1e-9));
    expect(d.radius, closeTo(2 * 0.5 * 1.4142135, 1e-6));
    final p = m.meshes[d.mesh][d.primitive]!;
    expect((p.firstIndex, p.indexCount), (0, 3));
    expect(p.streams['POSITION']!.stride, 12);
  });

  test('materials, cameras and lights are read', () {
    final m = GltfModel.read(_doc());
    final mat = m.materials.single;
    expect(mat.alphaMode, AlphaMode.mask);
    expect((mat.alphaCutoff, mat.metallic, mat.doubleSided), (0.3, 0.25, true));
    expect(m.cameras.single.world.getTranslation().z, 5);
    final l = m.lights.single;
    expect((l.type, l.intensity, l.range), ('point', 3, 4));
    expect(l.position.y, 2);
  });

  test('primitives are split into runs of triangles with their boxes', () {
    final b = GltfBuilder();
    final pos = b.addFloatAccessor(
      Float32List.fromList([
        for (var t = 0; t < 5; t++) ...[
          0, 0, t * 2.0, 1, 0, t * 2.0, 0, 1, t * 2.0 + 1, //
        ],
      ]),
      'VEC3',
      minMax: true,
    );
    final idx = b.addIndexAccessor(
      Uint16List.fromList([for (var i = 0; i < 15; i++) i]),
    );
    final mesh = b.addMesh('m', [
      {
        'attributes': {'POSITION': pos},
        'indices': idx,
      },
    ]);
    b.setScene([
      b.addNode({'mesh': mesh}),
    ]);
    final glb = readGlb(b.toGlb());
    final doc = GltfDocument(glb.json, [glb.bin]);
    final p = GltfModel.read(doc, clusterTriangles: 2).meshes[0][0]!;
    expect(p.clusterCount, 3);
    expect(p.clusters, [0, 6, 6, 6, 12, 3]);
    expect(p.clusterBounds.sublist(6, 12), [0, 0, 4, 1, 1, 7]);
    final whole = GltfModel.read(doc, clusterTriangles: 0).meshes[0][0]!;
    expect(whole.clusters, [0, 15]);
    expect(whole.clusterBounds, [0, 0, 0, 1, 1, 9]);
  });
}
