import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prismarine_assets/prismarine_assets.dart';
import 'package:vector_math/vector_math_64.dart';

import 'scene_node.dart';

/// The blend mode of a glTF material.
enum AlphaMode { opaque, mask, blend }

/// A glTF metallic-roughness material. A texture is the index of its image,
/// or null for none.
class ModelMaterial {
  ModelMaterial({
    required this.name,
    required this.baseColorFactor,
    required this.metallic,
    required this.roughness,
    required this.emissive,
    required this.alphaMode,
    required this.alphaCutoff,
    required this.doubleSided,
    required this.normalScale,
    this.baseColor,
    this.metallicRoughness,
    this.normal,
    this.emission,
  });

  /// The material that glTF gives a primitive without a material.
  factory ModelMaterial.fallback() => ModelMaterial(
    name: 'default',
    baseColorFactor: [1, 1, 1, 1],
    metallic: 1,
    roughness: 1,
    emissive: [0, 0, 0],
    alphaMode: AlphaMode.opaque,
    alphaCutoff: 0.5,
    doubleSided: false,
    normalScale: 1,
  );

  final String name;
  final List<double> baseColorFactor, emissive;
  final double metallic, roughness, alphaCutoff, normalScale;
  final AlphaMode alphaMode;
  final bool doubleSided;
  final int? baseColor, metallicRoughness, normal, emission;
}

/// A vertex input of a primitive: the buffer view that holds it, its offset
/// in the view, the stride of the view, its component type and count and
/// whether it is normalized.
class ModelStream {
  ModelStream(
    this.view,
    this.offset,
    this.stride,
    this.componentType,
    this.components,
    this.normalized,
  );
  final int view, offset, stride, componentType, components;
  final bool normalized;
}

/// A triangle primitive with 16-bit indices: its vertex inputs by glTF
/// attribute name, its index view with the first index and the count, and
/// the bounds of its positions.
class ModelPrimitive {
  ModelPrimitive(
    this.streams,
    this.indexView,
    this.firstIndex,
    this.indexCount,
    this.material,
    this.min,
    this.max, {
    Uint32List? clusters,
    Float32List? clusterBounds,
  }) : clusters = clusters ?? Uint32List.fromList([firstIndex, indexCount]),
       clusterBounds =
           clusterBounds ??
           Float32List.fromList([min.x, min.y, min.z, max.x, max.y, max.z]);
  final Map<String, ModelStream> streams;
  final int indexView, firstIndex, indexCount;
  final int? material;
  final Vector3 min, max;

  /// The runs of consecutive triangles of the primitive, as pairs of the
  /// first index and the index count. A renderer can draw and cull a run on
  /// its own, such as for the faces of a point light shadow.
  final Uint32List clusters;

  /// The box of the positions of each run of [clusters] in the space of the
  /// mesh, as the minimum x, y and z and then the maximum x, y and z.
  final Float32List clusterBounds;

  /// The number of runs in [clusters].
  int get clusterCount => clusters.length >> 1;
}

/// One primitive of a node in the scene: the mesh and primitive, the world
/// matrix and a sphere around it in world space.
class ModelDraw {
  ModelDraw(this.mesh, this.primitive, this.world, this.center, this.radius);
  final int mesh, primitive;
  final Matrix4 world;
  final Vector3 center;
  final double radius;
}

/// A perspective camera of the scene with its world matrix.
class ModelCamera {
  ModelCamera(this.name, this.world, this.yfov, this.znear, this.zfar);
  final String name;
  final Matrix4 world;
  final double yfov, znear;
  final double? zfar;
}

/// A light of `KHR_lights_punctual` with its place in the world. The light
/// shines along the negative z axis of its node.
class ModelLight {
  ModelLight(
    this.type,
    this.color,
    this.intensity,
    this.range,
    this.position,
    this.direction,
  );
  final String type;
  final Vector3 color, position, direction;
  final double intensity;
  final double? range;
}

/// The parts of a glTF that a renderer draws: the primitives of its meshes,
/// the draws of the default scene with their world matrices, the materials,
/// the cameras and the lights. A primitive that is not a triangle list with
/// 16-bit indices is left out and listed in [skipped].
class GltfModel {
  GltfModel._(
    this.meshes,
    this.materials,
    this.draws,
    this.cameras,
    this.lights,
    this.skipped,
    this.min,
    this.max,
  );

  /// Reads [doc]. Each primitive is split into [clusters] of at most
  /// [clusterTriangles] consecutive triangles, 4,096 by default. 0 keeps each
  /// primitive in one run.
  factory GltfModel.read(GltfDocument doc, {int clusterTriangles = 4096}) {
    final views = doc.list('bufferViews');
    final skipped = <String>[];
    final meshes = <List<ModelPrimitive?>>[];
    for (final (m, mesh) in doc.list('meshes').indexed) {
      meshes.add([
        for (final (p, prim) in (mesh['primitives'] as List).indexed)
          _primitive(
            doc,
            views,
            prim as Map<String, Object?>,
            clusterTriangles,
            () => skipped.add('mesh $m primitive $p'),
          ),
      ]);
    }
    final materials = [
      for (final m in doc.list('materials'))
        _material(m, (t) => imageOfTexture(doc, t)),
    ];
    final draws = <ModelDraw>[];
    final cameras = <ModelCamera>[];
    final lights = <ModelLight>[];
    final cameraDefs = doc.list('cameras');
    final lightDefs =
        (((doc.json['extensions'] as Map?)?['KHR_lights_punctual']
                    as Map?)?['lights']
                as List?)
            ?.cast<Map<String, Object?>>() ??
        const [];
    final min = Vector3.all(double.infinity);
    final max = Vector3.all(-double.infinity);
    for (final root in importSceneNodes(doc)) {
      root.walk((node) {
        final world = node.world.clone();
        if (node.mesh case final int mesh) {
          for (final (p, prim) in meshes[mesh].indexed) {
            if (prim == null) continue;
            final (c, r) = _sphere(prim, world);
            draws.add(ModelDraw(mesh, p, world, c, r));
            _growBox(prim, world, min, max);
          }
        }
        if (node.camera case final int cam) {
          final def = cameraDefs[cam];
          if (def['perspective'] case final Map p) {
            cameras.add(
              ModelCamera(
                node.name ?? 'camera $cam',
                world,
                (p['yfov'] as num).toDouble(),
                (p['znear'] as num).toDouble(),
                (p['zfar'] as num?)?.toDouble(),
              ),
            );
          }
        }
        if (node.light case final int l when l < lightDefs.length) {
          final def = lightDefs[l];
          final c = (def['color'] as List?)?.cast<num>() ?? const [1, 1, 1];
          lights.add(
            ModelLight(
              def['type'] as String,
              Vector3(c[0].toDouble(), c[1].toDouble(), c[2].toDouble()),
              ((def['intensity'] as num?) ?? 1).toDouble(),
              (def['range'] as num?)?.toDouble(),
              world.getTranslation(),
              (world.getRotation() * Vector3(0, 0, -1))..normalize(),
            ),
          );
        }
      });
    }
    return GltfModel._(
      meshes,
      materials,
      draws,
      cameras,
      lights,
      skipped,
      min,
      max,
    );
  }

  final List<List<ModelPrimitive?>> meshes;
  final List<ModelMaterial> materials;
  final List<ModelDraw> draws;
  final List<ModelCamera> cameras;
  final List<ModelLight> lights;
  final List<String> skipped;

  /// The box around every draw in world space.
  final Vector3 min, max;

  /// The material of [p], or the fallback material.
  ModelMaterial materialOf(ModelPrimitive p) =>
      p.material == null ? _fallback : materials[p.material!];

  static final _fallback = ModelMaterial.fallback();

  /// Grows [min] and [max] by the box of [p] in world space.
  static void _growBox(
    ModelPrimitive p,
    Matrix4 world,
    Vector3 min,
    Vector3 max,
  ) {
    final c = world.transformed3((p.min + p.max)..scale(0.5));
    final h = (p.max - p.min)..scale(0.5);
    final s = world.storage;
    // The half size of the box around the turned box.
    for (var r = 0; r < 3; r++) {
      final e = s[r].abs() * h.x + s[4 + r].abs() * h.y + s[8 + r].abs() * h.z;
      min[r] = math.min(min[r], c[r] - e);
      max[r] = math.max(max[r], c[r] + e);
    }
  }

  static (Vector3, double) _sphere(ModelPrimitive p, Matrix4 world) {
    final c = world.transformed3((p.min + p.max)..scale(0.5));
    final half = (p.max - p.min)..scale(0.5);
    // The largest scale of the matrix bounds the radius.
    final s = math.max(
      world.getColumn(0).xyz.length,
      math.max(world.getColumn(1).xyz.length, world.getColumn(2).xyz.length),
    );
    return (c, half.length * s);
  }

  static ModelPrimitive? _primitive(
    GltfDocument doc,
    List<Map<String, Object?>> views,
    Map<String, Object?> prim,
    int clusterTriangles,
    void Function() skip,
  ) {
    final idx = prim['indices'] as int?;
    if (((prim['mode'] as int?) ?? 4) != 4 || idx == null) {
      skip();
      return null;
    }
    final ia = doc.accessor(idx);
    if (ia['componentType'] != 5123 || ia['bufferView'] == null) {
      skip();
      return null;
    }
    final at = (ia['byteOffset'] as int?) ?? 0;
    final streams = <String, ModelStream>{};
    for (final MapEntry(:key, :value)
        in (prim['attributes'] as Map).cast<String, int>().entries) {
      final a = doc.accessor(value);
      final view = a['bufferView'] as int?;
      if (view == null) continue;
      final type = a['componentType'] as int;
      final n = doc.components(value);
      final size = switch (type) {
        5120 || 5121 => 1,
        5122 || 5123 => 2,
        _ => 4,
      };
      streams[key] = ModelStream(
        view,
        (a['byteOffset'] as int?) ?? 0,
        (views[view]['byteStride'] as int?) ?? size * n,
        type,
        n,
        a['normalized'] == true,
      );
    }
    final pos = doc.accessor((prim['attributes'] as Map)['POSITION'] as int);
    Vector3 corner(String k) {
      final l = (pos[k] as List?)?.cast<num>();
      if (l != null) {
        return Vector3(l[0].toDouble(), l[1].toDouble(), l[2].toDouble());
      }
      // Bounds from the data when the accessor has none.
      final f = doc.floats((prim['attributes'] as Map)['POSITION'] as int);
      final v = Vector3.all(k == 'min' ? double.infinity : -double.infinity);
      for (var i = 0; i + 2 < f.length; i += 3) {
        final p = Vector3(f[i], f[i + 1], f[i + 2]);
        k == 'min' ? Vector3.min(v, p, v) : Vector3.max(v, p, v);
      }
      return v;
    }

    final first = at ~/ 2, count = doc.count(idx);
    final runs = clusterTriangles <= 0 || count <= clusterTriangles * 3
        ? null
        : _clusters(
            doc.uints(idx),
            doc.floats((prim['attributes'] as Map)['POSITION'] as int),
            first,
            clusterTriangles * 3,
          );
    return ModelPrimitive(
      streams,
      ia['bufferView'] as int,
      first,
      count,
      prim['material'] as int?,
      corner('min'),
      corner('max'),
      clusters: runs?.$1,
      clusterBounds: runs?.$2,
    );
  }

  /// Splits [indices] into runs of [per] indices from [first] in the index
  /// view. Returns the first index and the count of each run and the box of
  /// the [positions] that it reads.
  static (Uint32List, Float32List) _clusters(
    Uint32List indices,
    Float32List positions,
    int first,
    int per,
  ) {
    final n = (indices.length + per - 1) ~/ per;
    final runs = Uint32List(n * 2), boxes = Float32List(n * 6);
    for (var c = 0; c < n; c++) {
      final start = c * per;
      final end = math.min(start + per, indices.length);
      runs[c * 2] = first + start;
      runs[c * 2 + 1] = end - start;
      var x0 = double.infinity, y0 = double.infinity, z0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity, z1 = -double.infinity;
      for (var i = start; i < end; i++) {
        final v = indices[i] * 3;
        final x = positions[v], y = positions[v + 1], z = positions[v + 2];
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
        if (z < z0) z0 = z;
        if (z > z1) z1 = z;
      }
      boxes
        ..[c * 6] = x0
        ..[c * 6 + 1] = y0
        ..[c * 6 + 2] = z0
        ..[c * 6 + 3] = x1
        ..[c * 6 + 4] = y1
        ..[c * 6 + 5] = z1;
    }
    return (runs, boxes);
  }

  static ModelMaterial _material(
    Map<String, Object?> m,
    int? Function(int texture) image,
  ) {
    final pbr = (m['pbrMetallicRoughness'] as Map?) ?? const {};
    int? tex(Object? info) => info is Map ? image(info['index'] as int) : null;
    List<double> nums(Object? l, List<double> d) => [
      for (final x in (l as List?) ?? d) (x as num).toDouble(),
    ];
    final normal = m['normalTexture'] as Map?;
    final strength =
        (((m['extensions'] as Map?)?['KHR_materials_emissive_strength']
                as Map?)?['emissiveStrength']
            as num?) ??
        1;
    return ModelMaterial(
      name: (m['name'] as String?) ?? '',
      baseColorFactor: nums(pbr['baseColorFactor'], const [1, 1, 1, 1]),
      metallic: ((pbr['metallicFactor'] as num?) ?? 1).toDouble(),
      roughness: ((pbr['roughnessFactor'] as num?) ?? 1).toDouble(),
      emissive: [
        for (final e in nums(m['emissiveFactor'], const [0, 0, 0]))
          e * strength,
      ],
      alphaMode: switch (m['alphaMode']) {
        'MASK' => AlphaMode.mask,
        'BLEND' => AlphaMode.blend,
        _ => AlphaMode.opaque,
      },
      alphaCutoff: ((m['alphaCutoff'] as num?) ?? 0.5).toDouble(),
      doubleSided: m['doubleSided'] == true,
      normalScale: ((normal?['scale'] as num?) ?? 1).toDouble(),
      baseColor: tex(pbr['baseColorTexture']),
      metallicRoughness: tex(pbr['metallicRoughnessTexture']),
      normal: tex(normal),
      emission: tex(m['emissiveTexture']),
    );
  }
}

/// The image of texture [texture] of [doc], or null.
int? imageOfTexture(GltfDocument doc, int? texture) =>
    texture == null ? null : doc.list('textures')[texture]['source'] as int?;
