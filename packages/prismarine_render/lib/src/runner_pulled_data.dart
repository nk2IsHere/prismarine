// Our renderer's cooked data on the GPU: the cooked scenes, their pools
// and texture arrays, read on first use or ahead of it.
part of 'frame_runner.dart';

/// Our renderer's cooked data for the passes it draws in pulled form
/// (the own-renderer design in docs/superpowers/specs, R0): the cooked
/// cache of a slice (`<slice>/cooked`: `shaders/`, and per scene its pools,
/// texture arrays and `cooked.json`), loaded on first use.
class Pulled {
  Pulled(this.root, this.shaders, this.layout);

  final String root;

  /// The names that the pulled passes find a draw's parts by, and the rows
  /// they fill.
  final PulledLayout layout;

  /// The render passes drawn in pulled form: the layout's, and its main
  /// pass with `PRISMARINE_PULLED_MAIN=1`.
  late final Set<String> passes = {
    ...layout.passes,
    if (envVar('PULLED_MAIN') == '1') layout.mainPass,
  };

  /// The pulled programs (`<root>/shaders`).
  final RenderAssets shaders;

  /// Cooked scene by directory name, read on first use; let go once no
  /// open scene asked for it since a close and no draw holds it.
  final _scenes = LooseMap<String, _CookedSceneGpu>();

  /// Each mesh stem's cooked scenes, in the listing's order (a mesh cooked
  /// into two scenes is the same bytes in both), and each cooked scene by
  /// its lower-case name.
  late final (Map<String, List<String>>, Map<String, String>) _cooked = () {
    final out = <String, List<String>>{}, names = <String, String>{};
    for (final d in Directory(root).listSync().whereType<Directory>()) {
      final f = File('${d.path}/cooked.json');
      if (!f.existsSync()) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      if (j['version'] != cookVersion) continue;
      // By the URI's segments: Windows lists with backslashes.
      final name = d.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      names[name.toLowerCase()] = name;
      for (final stem in (j['meshes']! as Map).keys) {
        (out[stem as String] ??= []).add(name);
      }
    }
    return (out, names);
  }();

  /// The scene shown (RenderHost, a scene file's name): a new draw takes a
  /// mesh cooked into it from its cooked scene before any other.
  String? shown;

  // alloc-cold: a draw's first pulled form.
  /// Mesh [stem]'s cooked scene for a draw of [scene] (null: the scene
  /// [shown]): that scene's own when the mesh is cooked into it, else one
  /// already read, else the first listed. Each cooked scene holds every
  /// pool its draws read, so the first listed (the slice's directory
  /// order) had Beacon Town's draws read the pools of seven other scenes,
  /// all held while it was open (331 MB of pools at the end of Ep205's
  /// playtest route, docs/areas/perf.md "Memory over an episode").
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

  /// The batch of mesh [stem] that starts at shipped index [start] with
  /// [count] indices, in its cooked scene for a draw of [scene]
  /// ([_sceneFor]), or null when not cooked.
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

  /// The next step of reading cooked scene [name] (a scene file's stem)
  /// ahead of its first frame: its JSON (read on the I/O thread), then a
  /// pool a step (read on the I/O thread, copied to the GPU), then a
  /// texture array a step, as sRGB when stored so (the view its colour
  /// inputs ask for). Whether it is all read (or has no cooked data).
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

  /// Each cooked scene's next [sceneAhead] step.
  final _aheadAt = <String, int>{};

  // alloc-cold: at a scene close's release.
  /// Lets go at once of the cooked scenes a release loosened whose buckets
  /// drew in no run since [before]: still alive, they are held only by
  /// draws no frame draws (a closed scene's, waiting for a collection),
  /// and their pools stayed on the GPU until an old-space collection
  /// (five of the seven cooked scenes counted at the end of Ep205's route,
  /// docs/areas/perf.md "Memory over an episode"). A draw that names one
  /// again makes its form again. Their names.
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

  /// Reads mesh [stem]'s cooked scene for a draw of [scene], if not read,
  /// off the UI isolate's frame (the file read on the I/O thread), and its
  /// batch's pool at [start] for [count] indices: what [batch] and the
  /// pass read synchronously at a scene's first frame (a cooked scene's
  /// JSON is up to ~1 MB, a pool up to ~22 MB).
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

/// The names that the pulled passes read a plan's draws by, and the rows
/// they fill. The application that cooks the data gives them.
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
    required this.uvTransforms,
    required this.cascadesBuffer,
    required this.frustumPlanes,
  });

  /// The rows of the objects and of the batches, which the cooked
  /// programs read.
  final RowLayout objectRow, instanceRow;

  /// The render passes drawn in pulled form, and the main pass that may be.
  final Set<String> passes;
  final String mainPass;

  /// The blocks of a draw that hold the camera, its object, its instance
  /// and its material's two parts.
  final String cameraBlock, objectBlock, instanceBlock;
  final String materialBaseBlock, materialMainBlock;

  /// The start of the names of the material textures, which the pulled
  /// passes read from texture arrays, followed by the input's number.
  final String materialTexturePrefix;

  /// The instance row's texture coordinate transforms, one vec4 each in a
  /// row. They stay at identity, as the cooked texture coordinates carry
  /// them.
  final List<String> uvTransforms;

  /// The frame buffer that holds the cascades of the key light's shadows.
  final String cascadesBuffer;

  /// All of [cascadesBuffer], made once.
  late final BufferRef cascadesRef = BufferRef(cascadesBuffer);

  /// The six planes of a view as its builder culls with them: left, right,
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

/// One cooked scene on the GPU: its pools' index and stream buffers and
/// its texture arrays, made on first use.
class _CookedSceneGpu {
  _CookedSceneGpu(this.dir, Map<String, Object?> json, RenderAssets shaders)
    : scene = CookedScene.fromJson(json),
      textures = shaders.atDirectory(dir);

  final String dir;
  final CookedScene scene;

  /// The last run one of its buckets drew in ([_RunnerPulled]'s prepare).
  int lastRun = 0;

  /// Let go ([Pulled.letGo]): its buffers are gone, and a draw whose
  /// pulled form names it makes its form again.
  bool dead = false;

  // alloc-cold: once per cooked scene let go.
  /// Lets go of its pools' device buffers now (G17), not when a collection
  /// finds the last draw that named it gone.
  void free() {
    dead = true;
    for (final p in _pools.values) {
      p.indices.buffer.mcsmRelease();
      for (final v in p.streams.values) {
        v.buffer.mcsmRelease();
      }
    }
    _pools.clear();
  }

  /// Loads the arrays as slice textures (`textures/<stem>.ktx2`).
  final RenderAssets textures;
  final _pools = <int, _PoolGpu>{};

  _PoolGpu pool(int i) => _pools[i] ?? (_pools[i] = _makePool(i));

  /// Pool [i] made, its file read on the I/O thread ([Pulled.readAhead]).
  Future<void> poolAhead(int i) async {
    if (_pools.containsKey(i)) return;
    final bytes = await File('$dir/${scene.pools[i].file}').readAsBytes();
    _pools[i] ??= _makePool(i, bytes);
  }

  // The miss path apart: an inline closure capturing the key gave every
  // call a context, hits included (perf).
  _PoolGpu _makePool(int i, [Uint8List? read]) {
    final parts = cookedPoolParts(
      read ?? File('$dir/${scene.pools[i].file}').readAsBytesSync(),
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

  /// By stream name (`POSITION`, `UV5`, `_COLOR_1`, …).
  final Map<String, gpu.BufferView> streams;

  /// [_poolStream]'s answers by storage name.
  final byStorage = <String, gpu.BufferView>{};
}

/// Vulkan's sRGB formats among the cooked arrays' (R8G8B8A8, B8G8R8A8,
/// BC1 RGB and RGBA, BC2, BC3, BC7).
const _srgbFormats = {43, 50, 132, 134, 136, 138, 146};
