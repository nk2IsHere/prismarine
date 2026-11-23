/// The output of the cook for one scene, as the renderer loads it. It
/// describes the cooked files under `<content>/cooked/<scene>/` and the place
/// of each mesh batch and texture in them. The files are derived from the
/// editable content and are not edited.
library;

/// The version of the cooked files, raised when their meaning changes. A
/// cache of another version is cooked again.
const cookVersion = 5;

/// The material textures of one (width, height, format, levels) group as one
/// KTX2 2D array. Layer i holds the image of [layers][i] with the bytes of
/// the content.
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

  /// The texture stem of the array, `textures/<file>.ktx2` in the cooked
  /// scene.
  final String file;
  final int width, height, vkFormat, levels;

  /// The texture stems by layer.
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

/// Every static batch of one vertex layout, concatenated into one glTF
/// buffer and one 32-bit index buffer. The buffer holds one stream per
/// attribute, each an accessor over all vertices of the pool.
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

  /// The attributes in name order, each of the form `NAME:componentType:type`
  /// in the terms of glTF and joined by `|`.
  final String layout;
  final int vertexCount, indexCount;

  Map<String, Object?> toJson() => {
    'file': file,
    'layout': layout,
    'vertexCount': vertexCount,
    'indexCount': indexCount,
  };
}

/// The place of one batch, a glTF primitive, of a mesh in the cooked files.
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

  /// The index into [CookedScene.pools].
  final int pool;
  final int firstIndex, indexCount, baseVertex;

  /// The material index of the primitive in the glTF of its mesh.
  final int material;

  /// The first index of the batch in the index buffer of its source mesh.
  /// A draw of the source streams finds its batch by this index. It is -1
  /// when the source does not give it.
  final int startIndex;

  /// The bounding sphere of the batch in mesh space as centre x, y, z and
  /// radius. The culling on the GPU tests the batch against it. A negative
  /// radius marks an unknown sphere. Such a batch is not culled.
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

  /// True for a shadow batch. Its indices are those of the shadow index
  /// buffer of the mesh, index buffer 1, from the `shadowBatches` of the
  /// editable mesh.
  final bool shadow;

  /// Returns the batch of [batches] that starts at the shipped index [start]
  /// with [count] indices, or null. The indices are those of the default
  /// index buffer, or those of the shadow index buffer with [shadow].
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

  /// Each input file, relative to the content directory, with its content
  /// hash. The cache is stale when any hash differs.
  final Map<String, String> inputs;
  final List<CookedArray> arrays;
  final List<CookedPool> pools;

  /// The batches by mesh stem, in glTF primitive order.
  final Map<String, List<CookedBatch>> meshes;

  /// Returns the (array, layer) of the texture [stem], or null when no array
  /// holds it.
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
