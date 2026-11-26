// The cooked data on the GPU, with the cooked scenes and their pools and
// texture arrays, read on first use or ahead of it.
part of 'frame_runner.dart';

/// The cooked data for the passes drawn in pulled form, a cooked directory with
/// the programs in `shaders/` and per scene its pools, texture arrays and
/// `cooked.json`, loaded on first use.
class Pulled {
  Pulled(this.root, this.shaders, this.layout);

  final String root;

  /// The names of the parts of a draw and the rows that the pulled passes
  /// fill.
  final PulledLayout layout;

  /// The render passes drawn in pulled form, those of the layout and its
  /// main pass with `PRISMARINE_PULLED_MAIN=1`.
  late final Set<String> passes = {
    ...layout.passes,
    if (envVar('PULLED_MAIN') == '1') layout.mainPass,
  };

  /// The pulled programs in `<root>/shaders`.
  final RenderAssets shaders;

  /// The cooked scenes by directory name, read on first use. A scene is let
  /// go once no open scene asked for it since a close and no draw holds it.
  final _scenes = LooseMap<String, _CookedSceneGpu>();

  /// The cooked scenes of each mesh stem in the order of the listing and each
  /// cooked scene by its lower-case name. A mesh cooked into two scenes has the
  /// same bytes in both.
  late final (Map<String, List<String>>, Map<String, String>) _cooked = () {
    final out = <String, List<String>>{}, names = <String, String>{};
    for (final d in Directory(root).listSync().whereType<Directory>()) {
      final f = File('${d.path}/cooked.json');
      if (!f.existsSync()) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      if (j['version'] != cookVersion) continue;
      // By the segments of the URI, since Windows lists with backslashes.
      final name = d.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      names[name.toLowerCase()] = name;
      for (final stem in (j['meshes']! as Map).keys) {
        (out[stem as String] ??= []).add(name);
      }
    }
    return (out, names);
  }();

  /// The name of the scene file shown. A new draw takes a mesh cooked into
  /// it from its cooked scene before any other.
  String? shown;

  // alloc-cold: a draw's first pulled form.
  /// Returns the cooked scene of the mesh [stem] for a draw of [scene], or
  /// of the scene [shown] when [scene] is null. It is the own cooked scene of
  /// that scene when the mesh is cooked into it, else one already read, else
  /// the first listed. Each cooked scene holds every pool that its draws
  /// read. The first listed scene in directory order would make the draws of
  /// a scene read and hold the pools of other scenes.
  String? _sceneFor(String stem, String? scene) {
    final at = _cooked.$1[stem];
    if (at == null) return null;
    if (at.length == 1) return at[0];
    for (final want in [scene, shown]) {
      if (want == null) continue;
      final lower = want.toLowerCase();
      final n =
          _cooked.$2[lower.endsWith('.scene')
              ? lower.substring(0, lower.length - 6)
              : lower];
      if (n != null && at.contains(n)) return n;
    }
    for (final n in at) {
      if (_scenes.holds(n)) return n;
    }
    return at.first;
  }

  /// Returns the batch of the mesh [stem] that starts at the shipped index
  /// [start] with [count] indices, in its cooked scene for a draw of [scene]
  /// ([_sceneFor]), or null when it is not cooked.
  (_CookedSceneGpu, CookedBatch)? batch(
    String stem,
    int start,
    int count, {
    bool shadow = false,
    String? scene,
  }) {
    final name = _sceneFor(stem, scene);
    if (name == null) return null;
    final s = _scenes[name] ??= _CookedSceneGpu(
      '$root/$name',
      jsonDecode(File('$root/$name/cooked.json').readAsStringSync())
          as Map<String, Object?>,
      shaders,
    );
    final list = s.scene.meshes[stem];
    final b = list == null
        ? null
        : CookedBatch.at(list, start, count, shadow: shadow);
    return b == null ? null : (s, b);
  }

  /// Runs the next step of reading the cooked scene [name], the stem of a
  /// scene file, ahead of its first frame. The first step reads its JSON on
  /// the I/O thread. Each next step reads a pool on the I/O thread and
  /// copies it to the GPU, then each step reads a texture array, as sRGB
  /// when it is stored so. Returns true when it is all read or has no cooked
  /// data.
  Future<bool> sceneAhead(String name) async {
    final dir = '$root/$name';
    if (!_cooked.$2.containsValue(name)) return true;
    final s = _scenes[name];
    if (s == null) {
      final text = await File('$dir/cooked.json').readAsString();
      _scenes[name] ??= _CookedSceneGpu(
        dir,
        jsonDecode(text) as Map<String, Object?>,
        shaders,
      );
      return false;
    }
    final step = _aheadAt[name] ?? 0;
    final pools = s.scene.pools.length, arrays = s.scene.arrays;
    if (step >= pools + arrays.length) return true;
    _aheadAt[name] = step + 1;
    if (step < pools) {
      await s.poolAhead(step);
    } else {
      final a = arrays[step - pools];
      s.textures.texture(a.file, srgb: _srgbFormats.contains(a.vkFormat));
    }
    return false;
  }

  /// The next [sceneAhead] step of each cooked scene.
  final _aheadAt = <String, int>{};

  // alloc-cold: at a scene close's release.
  /// Lets go at once of the cooked scenes that a release loosened and whose
  /// buckets drew in no run since [before]. Such a scene is held only by
  /// draws that no frame draws, such as those of a closed scene that wait
  /// for a collection. Its pools would stay on the GPU until an old-space
  /// collection. A draw that uses one again makes its form again. Returns
  /// the names of the scenes.
  List<String> letGo(int before) {
    final out = <String>[];
    for (final (name, s) in _scenes.looseEntries) {
      if (s.lastRun >= before) continue;
      _scenes.remove(name);
      _aheadAt.remove(name);
      s.free();
      out.add(name);
    }
    return out;
  }

  /// Reads the cooked scene of the mesh [stem] for a draw of [scene], if not
  /// read, away from the frame of the UI isolate with the file read on the
  /// I/O thread. Reads the pool of its batch at [start] for [count] indices
  /// too. [batch] and the pass would otherwise read them synchronously at the
  /// first frame of a scene.
  Future<void> readAhead(
    String stem,
    int start,
    int count, {
    bool shadow = false,
    String? scene,
  }) async {
    final name = _sceneFor(stem, scene);
    if (name == null) return;
    if (_scenes[name] == null) {
      final text = await File('$root/$name/cooked.json').readAsString();
      _scenes[name] ??= _CookedSceneGpu(
        '$root/$name',
        jsonDecode(text) as Map<String, Object?>,
        shaders,
      );
    }
    final found = batch(stem, start, count, shadow: shadow, scene: scene);
    if (found == null) return;
    final (s, b) = found;
    await s.poolAhead(b.pool);
  }
}

/// The names of the parts of a plan's draws and the rows that the pulled
/// passes fill. The application that cooks the data gives them.
class PulledLayout {
  PulledLayout({
    required this.objectRow,
    required this.instanceRow,
    required this.passes,
    required this.mainPass,
    required this.cameraBlock,
    required this.objectBlock,
    required this.instanceBlock,
    required this.materialBaseBlock,
    required this.materialMainBlock,
    required this.materialTexturePrefix,
    this.materialTextures = const [],
    this.keepOrder = false,
    this.unculled = const {},
    required this.uvTransforms,
    required this.cascadesBuffer,
    required this.frustumPlanes,
  });

  /// The rows of the objects and of the batches, which the cooked
  /// programs read.
  final RowLayout objectRow, instanceRow;

  /// The render passes drawn in pulled form. The main pass is drawn in
  /// pulled form on request.
  final Set<String> passes;
  final String mainPass;

  /// The blocks of a draw that hold the camera, its object, its instance
  /// and its material's two parts.
  final String cameraBlock, objectBlock, instanceBlock;
  final String materialBaseBlock, materialMainBlock;

  /// The start of the names of the material textures, which the pulled
  /// passes read from texture arrays, followed by the input's number.
  final String materialTexturePrefix;

  /// The material textures by name, for programs that name them by their
  /// function: each one's layer slot is its place in the list. When it is
  /// empty, [materialTexturePrefix] and a number name them.
  final List<String> materialTextures;

  /// Whether the pulled draws keep the plan's order: a bucket then holds one
  /// run of draws with the same key, not every draw of the key. A game
  /// whose opaque draws test depth less-or-equal without a depth prepass
  /// needs it, as the last draw wins a tie of depth.
  final bool keepOrder;

  /// The passes of [passes] whose draws have cameras of their own, such as a
  /// shadow atlas with a camera per tile: one view's planes would cull them
  /// wrongly, so their buckets draw every cluster.
  final Set<String> unculled;

  /// Whether [name] is a material texture. It allocates nothing, as the
  /// binds of every frame ask it.
  bool isMaterialTexture(String name) => materialTextures.isNotEmpty
      ? materialTextures.contains(name)
      : name.startsWith(materialTexturePrefix);

  /// Returns the layer slot of the material texture [name], or -1 when
  /// [name] is not a material texture.
  // alloc-cold: a draw's first pulled form.
  int materialTextureSlot(String name) {
    if (materialTextures.isNotEmpty) return materialTextures.indexOf(name);
    if (!name.startsWith(materialTexturePrefix)) return -1;
    return int.tryParse(name.substring(materialTexturePrefix.length)) ?? -1;
  }

  /// The instance row's texture coordinate transforms, one vec4 each in a
  /// row. They stay at identity, as the cooked texture coordinates carry
  /// them.
  final List<String> uvTransforms;

  /// The frame buffer that holds the cascades of the key light's shadows.
  final String cascadesBuffer;

  /// All of [cascadesBuffer], made once.
  late final BufferRef cascadesRef = BufferRef(cascadesBuffer);

  /// The six planes of a view, as the builder computes them, left, right,
  /// bottom, top, near and far, each a unit normal and a distance, from the
  /// view-projection matrix of 16 floats in the camera block.
  final List<double> Function(List<double> viewProjection) frustumPlanes;

  /// The blocks that a pulled draw reads from its rows, not from its bucket.
  late final Set<String> rowBlocks = {
    objectBlock,
    instanceBlock,
    materialBaseBlock,
    materialMainBlock,
  };
}

/// One cooked scene on the GPU with the index and stream buffers of its
/// pools and its texture arrays, made on first use.
class _CookedSceneGpu {
  // alloc-cold: a cooked scene's first use.
  _CookedSceneGpu(this.dir, Map<String, Object?> json, RenderAssets shaders)
    : scene = CookedScene.fromJson(json),
      textures = shaders.atDirectory(dir);

  final String dir;
  final CookedScene scene;

  /// The last run in which one of its buckets drew, set by the prepare of
  /// [_RunnerPulled].
  int lastRun = 0;

  /// True after [Pulled.letGo]. Its buffers are gone. A draw whose pulled
  /// form uses it makes its form again.
  bool dead = false;

  // alloc-cold: once per cooked scene let go.
  /// Lets go of the device buffers of its pools now (G17), not when a
  /// collection finds the last draw that used it gone.
  void free() {
    dead = true;
    for (final p in _pools.values) {
      p.indices.buffer.prismarineRelease();
      for (final v in p.streams.values) {
        v.buffer.prismarineRelease();
      }
    }
    _pools.clear();
  }

  /// Loads the arrays as textures of the cooked scene's directory.
  final RenderAssets textures;
  final _pools = <int, _PoolGpu>{};

  _PoolGpu pool(int i) => _pools[i] ?? (_pools[i] = _makePool(i));

  /// Makes the pool [i] with its file read on the I/O thread
  /// ([Pulled.readAhead]).
  Future<void> poolAhead(int i) async {
    if (_pools.containsKey(i)) return;
    final path = '$dir/${scene.pools[i].file}';
    // A compressed pool is inflated on a worker, its bytes handed back
    // without a copy: a large pool takes most of a second.
    final bytes = path.endsWith('.gz')
        ? (await Isolate.run(
            () => TransferableTypedData.fromList([
              _inflated(File(path).readAsBytesSync()),
            ]),
          )).materialize().asUint8List()
        : await File(path).readAsBytes();
    _pools[i] ??= _makePool(i, bytes);
  }

  /// The GLB of a pool file read whole: a `.glb.gz` inflated.
  static Uint8List _inflated(Uint8List gz) => switch (gzip.decode(gz)) {
    final Uint8List b => b,
    final b => Uint8List.fromList(b),
  };

  // The miss path is a method of its own. An inline closure that captures
  // the key would allocate a context on every call.
  // alloc-cold: a pool's first use.
  _PoolGpu _makePool(int i, [Uint8List? read]) {
    final path = '$dir/${scene.pools[i].file}';
    final parts = cookedPoolParts(
      read ??
          (path.endsWith('.gz')
              ? _inflated(File(path).readAsBytesSync())
              : File(path).readAsBytesSync()),
    );
    gpu.BufferView view(Uint8List b) {
      gpu.GpuMemory.tag = 'buffer.pulledPool';
      final buf = gpu.gpuContext.createDeviceBufferWithCopy(
        ByteData.sublistView(b.isEmpty ? Uint8List(16) : b),
      );
      gpu.GpuMemory.tag = null;
      return gpu.BufferView(
        buf,
        offsetInBytes: 0,
        lengthInBytes: buf.sizeInBytes,
      );
    }

    return _PoolGpu(view(parts.indices), {
      for (final MapEntry(:key, :value) in parts.streams.entries)
        key: view(value),
    });
  }
}

class _PoolGpu {
  _PoolGpu(this.indices, this.streams);
  final gpu.BufferView indices;

  /// The streams by name, such as `POSITION`, `UV5` and `_COLOR_1`.
  final Map<String, gpu.BufferView> streams;

  /// The results of [_poolStream] by storage name.
  final byStorage = <String, gpu.BufferView>{};
}

/// The Vulkan sRGB formats among those of the cooked arrays, R8G8B8A8,
/// B8G8R8A8, BC1 RGB and RGBA, BC2, BC3 and BC7.
const _srgbFormats = {43, 50, 132, 134, 136, 138, 146};
