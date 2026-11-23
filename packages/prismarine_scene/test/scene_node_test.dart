import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:prismarine_scene/model.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('a node in the world is the product of the transforms above it', () {
    final root = SceneNode(local: Matrix4.translationValues(10, 0, 0));
    final mid = SceneNode(local: Matrix4.diagonal3Values(2, 2, 2));
    final leaf = SceneNode(local: Matrix4.translationValues(0, 1, 0));
    root.add(mid);
    mid.add(leaf);
    expect(leaf.world.getTranslation(), Vector3(10, 2, 0));
    root.setLocal(Matrix4.translationValues(0, 0, 5));
    expect(leaf.world.getTranslation(), Vector3(0, 2, 5));
    mid.remove(leaf);
    expect(leaf.parent, isNull);
    expect(leaf.world.getTranslation(), Vector3(0, 1, 0));
    root.add(leaf);
    expect(leaf.world.getTranslation(), Vector3(0, 1, 5));
    expect(mid.children, isEmpty);
  });

  test('the import keeps names, indices, extras and the scene roots', () {
    final json = <String, Object?>{
      'scene': 1,
      'scenes': [
        {'nodes': <int>[]},
        {
          'nodes': [2],
        },
      ],
      'nodes': [
        {
          'name': 'cam',
          'camera': 0,
          'matrix': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 4, 5, 1],
        },
        {
          'mesh': 1,
          'scale': [2, 2, 2],
          'extras': {'tag': 'a'},
        },
        {
          'translation': [1, 0, 0],
          'children': [0, 1],
          'extensions': {
            'KHR_lights_punctual': {'light': 2},
          },
        },
      ],
    };
    final roots = importSceneNodes(GltfDocument(json, [Uint8List(0)]));
    expect(roots, hasLength(1));
    final r = roots.single;
    expect(r.light, 2);
    expect(r.name, isNull);
    final [cam, mesh] = r.children;
    expect((cam.name, cam.camera), ('cam', 0));
    expect(cam.world.getTranslation(), Vector3(4, 4, 5));
    expect(mesh.mesh, 1);
    expect(mesh.extras, {'tag': 'a'});
    expect(mesh.world.getMaxScaleOnAxis(), 2);
  });

  test('without scenes each node that is no child is a root', () {
    final json = <String, Object?>{
      'nodes': [
        {
          'children': [1],
        },
        <String, Object?>{},
        <String, Object?>{},
      ],
    };
    final roots = importSceneNodes(GltfDocument(json, const []));
    expect(roots, hasLength(2));
    expect(roots.first.children, hasLength(1));
  });
}
