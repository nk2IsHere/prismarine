/// The cook's output for one scene, as the renderer loads it: what the
/// cooked files under `<slice>/cooked/<scene>/` hold and where each mesh
/// batch and texture went. Derived from the editable slice and never edited
/// (the own-renderer design in docs/superpowers/specs, "Data").
library;

/// Bumped when the cooked files' meaning changes; a cache of another
/// version is cooked again.
const cookVersion = 5;

/// Material textures of one (width, height, format, levels) group, as one
/// KTX2 2D array: layer i is [layers][i]'s image, bytes as the slice has
/// them.
class CookedArray {
  CookedArray({
    required this.file,
    required this.width,
    required this.height,
    required this.vkFormat,
    required this.levels,
    required this.layers,
  });

  factory CookedArray.fromJson(Map<String, Object?> j) => CookedArray(
    file: j['file']! as String,
    width: j['width']! as int,
    height: j['height']! as int,
    vkFormat: j['vkFormat']! as int,
    levels: j['levels']! as int,
    layers: [for (final s in j['layers']! as List) s as String],
  );

  /// The array's texture stem: `textures/<file>.ktx2` in the cooked scene.
  final String file;
  final int width, height, vkFormat, levels;

  /// Texture stems by layer.
  final List<String> layers;

  Map<String, Object?> toJson() => {
    'file': file,
    'width': width,
    'height': height,
    'vkFormat': vkFormat,
    'levels': levels,
    'layers': layers,
  };
}

/// Every static batch of one vertex layout, concatenated: one glTF buffer
/// of interleaved-free streams (each attribute its own accessor over all
/// the pool's vertices) and one 32-bit index buffer.
class CookedPool {
  CookedPool({
    required this.file,
    required this.layout,
    required this.vertexCount,
    required this.indexCount,
  });

  factory CookedPool.fromJson(Map<String, Object?> j) => CookedPool(
    file: j['file']! as String,
    layout: j['layout']! as String,
    vertexCount: j['vertexCount']! as int,
    indexCount: j['indexCount']! as int,
  );

  final String file;

  /// The attributes, as `NAME:componentType:type` joined by `|` in name
  /// order (glTF's terms).
  final String layout;
  final int vertexCount, indexCount;

  Map<String, Object?> toJson() => {
    'file': file,
    'layout': layout,
    'vertexCount': vertexCount,
    'indexCount': indexCount,
  };
}

/// Where one batch (glTF primitive) of a mesh went.
class CookedBatch {
  CookedBatch({
    required this.pool,
    required this.firstIndex,
    required this.indexCount,
    required this.baseVertex,
    required this.material,
    this.startIndex = -1,
    this.sphere = const [0, 0, 0, -1],
    this.shadow = false,
  });

  factory CookedBatch.fromJson(List<Object?> j) => CookedBatch(
    pool: j[0]! as int,
    firstIndex: j[1]! as int,
    indexCount: j[2]! as int,
    baseVertex: j[3]! as int,
    material: j[4]! as int,
    startIndex: j.length > 5 ? j[5]! as int : -1,
    sphere: j.length > 6
        ? [for (final v in j[6]! as List) (v as num).toDouble()]
        : const [0, 0, 0, -1],
    shadow: j.length > 7 && j[7] == true,
  );

  /// Index into [CookedScene.pools].
  final int pool;
  final int firstIndex, indexCount, baseVertex;

  /// The primitive's material index in its mesh's glTF.
  final int material;

  /// The shipped batch's first index in its mesh's index buffer
  /// (T3MeshBatch mStartIndex, the primitive's extras), by which a draw of
  /// the shipped streams finds its batch; -1 when the extras lack it.
  final int startIndex;

  /// The batch's bounding sphere in mesh space (centre xyz, radius; T3MeshBatch
  /// mBoundingSphere), which the GPU's culling tests; a negative radius:
  /// unknown, never culled.
  final List<double> sphere;

  List<Object?> toJson() => [
    pool,
    firstIndex,
    indexCount,
    baseVertex,
    material,
    startIndex,
    sphere,
    shadow,
  ];

  /// A shadow batch: its indices are the mesh's shadow index buffer's
  /// (index buffer 1; the editable mesh's `shadowBatches`).
  final bool shadow;

  /// The batch of [batches] that starts at shipped index [start] with
  /// [count] indices of the default batches' index buffer, or of the shadow
  /// batches' with [shadow], or null.
  static CookedBatch? at(
    List<CookedBatch> batches,
    int start,
    int count, {
    bool shadow = false,
  }) {
    for (final b in batches) {
      if (b.startIndex == start &&
          b.indexCount == count &&
          b.shadow == shadow) {
        return b;
      }
    }
    return null;
  }
}

class CookedScene {
  CookedScene({
    required this.scene,
    required this.inputs,
    required this.arrays,
    required this.pools,
    required this.meshes,
  });

  factory CookedScene.fromJson(Map<String, Object?> j) => CookedScene(
    scene: j['scene']! as String,
    inputs: (j['inputs']! as Map).cast<String, String>(),
    arrays: [
      for (final a in j['arrays']! as List)
        CookedArray.fromJson((a as Map).cast()),
    ],
    pools: [
      for (final p in j['pools']! as List)
        CookedPool.fromJson((p as Map).cast()),
    ],
    meshes: {
      for (final MapEntry(:key, :value) in (j['meshes']! as Map).entries)
        key as String: [
          for (final b in value as List) CookedBatch.fromJson(b as List),
        ],
    },
  );

  final String scene;

  /// Each input file (slice-relative path) and its content hash: the cache
  /// is stale when any differs.
  final Map<String, String> inputs;
  final List<CookedArray> arrays;
  final List<CookedPool> pools;

  /// Batches by mesh stem, in glTF primitive order.
  final Map<String, List<CookedBatch>> meshes;

  /// (array, layer) of texture [stem], or null when no array holds it.
  (int, int)? textureAt(String stem) {
    final at = _textureIndex[stem];
    return at;
  }

  late final _textureIndex = <String, (int, int)>{
    for (var a = 0; a < arrays.length; a++)
      for (var l = 0; l < arrays[a].layers.length; l++)
        arrays[a].layers[l]: (a, l),
  };

  Map<String, Object?> toJson() => {
    'version': cookVersion,
    'scene': scene,
    'inputs': inputs,
    'arrays': [for (final a in arrays) a.toJson()],
    'pools': [for (final p in pools) p.toJson()],
    'meshes': {
      for (final MapEntry(:key, :value) in meshes.entries)
        key: [for (final b in value) b.toJson()],
    },
  };
}
