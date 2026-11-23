import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:vector_math/vector_math_64.dart';

/// A node of a scene with its transform, its children and the parts of a
/// glTF document that it carries by index. A node keeps its world transform
/// and computes it again only after its local transform or the transform of
/// an ancestor changed, or after it moved to another parent.
class SceneNode {
  SceneNode({
    this.name,
    Matrix4? local,
    this.mesh,
    this.camera,
    this.light,
    this.skin,
    this.extras,
  }) : _local = local?.clone() ?? Matrix4.identity();

  /// The name of the node, null for a glTF node without one.
  String? name;

  /// The mesh, camera, skin and `KHR_lights_punctual` light of the node, by
  /// their index in the document.
  final int? mesh, camera, light, skin;

  /// The `extras` of the glTF node.
  final Object? extras;

  final Matrix4 _local;
  final Matrix4 _world = Matrix4.identity();
  bool _dirty = true;
  SceneNode? _parent;
  final List<SceneNode> _children = [];

  SceneNode? get parent => _parent;
  List<SceneNode> get children => List.unmodifiable(_children);

  /// The transform relative to the parent. Change it through [setLocal].
  Matrix4 get local => _local;

  /// Copies [m] into the local transform.
  void setLocal(Matrix4 m) {
    _local.setFrom(m);
    _markDirty();
  }

  /// The transform in the world, the product of the local transforms from
  /// the root down to this node.
  Matrix4 get world {
    if (_dirty) {
      final p = _parent;
      if (p == null) {
        _world.setFrom(_local);
      } else {
        _world
          ..setFrom(p.world)
          ..multiply(_local);
      }
      _dirty = false;
    }
    return _world;
  }

  /// Adds [child] at the end of the children. A child with a parent leaves
  /// it first.
  void add(SceneNode child) {
    child._parent?.remove(child);
    child._parent = this;
    _children.add(child);
    child._markDirty();
  }

  /// Removes [child] from the children. Returns false when it is no child.
  bool remove(SceneNode child) {
    if (!_children.remove(child)) return false;
    child._parent = null;
    child._markDirty();
    return true;
  }

  /// Calls [visit] on this node and on every node below it, parents first,
  /// in the order of the children.
  void walk(void Function(SceneNode node) visit) {
    visit(this);
    for (final c in _children) {
      c.walk(visit);
    }
  }

  void _markDirty() {
    if (_dirty) return;
    _dirty = true;
    for (final c in _children) {
      c._markDirty();
    }
  }
}

/// Returns the roots of the default scene of [doc] with their nodes below
/// them. A document without scenes gives each node that is no child as a
/// root. A node has the local transform of its matrix, or else of its
/// translation, rotation and scale.
List<SceneNode> importSceneNodes(GltfDocument doc) {
  final defs = doc.list('nodes');
  final nodes = [
    for (final n in defs)
      SceneNode(
        name: n['name'] as String?,
        local: localTransform(n),
        mesh: n['mesh'] as int?,
        camera: n['camera'] as int?,
        skin: n['skin'] as int?,
        light:
            ((n['extensions'] as Map?)?['KHR_lights_punctual']
                    as Map?)?['light']
                as int?,
        extras: n['extras'],
      ),
  ];
  final isChild = List.filled(nodes.length, false);
  for (final (i, n) in defs.indexed) {
    for (final c in ((n['children'] as List?) ?? const []).cast<int>()) {
      nodes[i].add(nodes[c]);
      isChild[c] = true;
    }
  }
  final scenes = doc.list('scenes');
  if (scenes.isEmpty) {
    return [
      for (var i = 0; i < nodes.length; i++)
        if (!isChild[i]) nodes[i],
    ];
  }
  final scene = scenes[(doc.json['scene'] as int?) ?? 0];
  return [
    for (final r in ((scene['nodes'] as List?) ?? const []).cast<int>())
      nodes[r],
  ];
}

/// Returns the local transform of the glTF node [node], from its matrix or
/// from its translation, rotation and scale.
Matrix4 localTransform(Map<String, Object?> node) {
  if (node['matrix'] case final List m) {
    return Matrix4.fromList([for (final v in m) (v as num).toDouble()]);
  }
  List<double> v(String k, List<double> d) => [
    for (final x in (node[k] as List?) ?? d) (x as num).toDouble(),
  ];
  final t = v('translation', const [0, 0, 0]);
  final r = v('rotation', const [0, 0, 0, 1]);
  final s = v('scale', const [1, 1, 1]);
  return Matrix4.compose(
    Vector3(t[0], t[1], t[2]),
    Quaternion(r[0], r[1], r[2], r[3]),
    Vector3(s[0], s[1], s[2]),
  );
}
