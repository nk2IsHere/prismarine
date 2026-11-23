part of 'frame_runner.dart';

/// Binding lookups kept across draws and frames: a slot object resolves its
/// name in the engine on first use, so a slot made per bind paid a native
/// name lookup on every draw; and a frame's constant blocks are shared by
/// many draws (the camera, the scene, a light group's blocks), so each is
/// written to the uniform ring once per frame and its view rebound.
extension _RunnerSlots on FrameRunner {
  // One map per kind and shader, looked up by the name itself: a key string
  // ('u' + name) and a closure per lookup were garbage on every bind.
  _SlotMaps _slotMapsOf(gpu.Shader s) => _slots[s] ??= _SlotMaps();

  gpu.UniformSlot _uniformSlot(gpu.Shader s, String name) {
    final m = _slotMapsOf(s).uniforms;
    return m[name] ??= s.getUniformSlot(name);
  }

  gpu.StorageSlot _textureSlot(gpu.Shader s, String name) {
    final m = _slotMapsOf(s).textures;
    return m[name] ??= s.getSeparateTextureSlot(name);
  }

  gpu.StorageSlot _samplerSlot(gpu.Shader s, int slot) {
    final m = _slotMapsOf(s).samplers;
    return m[slot] ??= s.getSeparateSamplerSlot('s$slot');
  }

  gpu.StorageSlot _texelSlot(gpu.Shader s, String name) {
    final m = _slotMapsOf(s).texels;
    return m[name] ??= s.getTexelBufferSlot(name);
  }

  gpu.StorageSlot _imageSlot(gpu.Shader s, String name) {
    final m = _slotMapsOf(s).images;
    return m[name] ??= s.getStorageImageSlot(name);
  }

  gpu.StorageSlot _bufferSlot(gpu.Shader s, String name) {
    final m = _slotMapsOf(s).buffers;
    return m[name] ??= s.getStorageBufferSlot(name);
  }

  /// [bytes] as a block of [want] bytes (its declared rows; zero-padded when
  /// the plan's block is shorter), written once per frame.
  gpu.BufferView _uniform(UniformRing host, Uint8List? block, int want) {
    // A frame role binds the frame's bytes for it (FrameRole).
    final bytes = block != null && block.isEmpty
        ? _frameBlocks[block] ?? block
        : block;
    return _uniformEntry(host, bytes, want).view;
  }

  /// [_uniform] of a stage's [i]th block through the entry the stage keeps
  /// for it ([c]'s, a block of bytes, not a role's): a kept draw's blocks
  /// bind without a lookup by block.
  gpu.BufferView _stageUniform(UniformRing host, _StageInputs c, int i) {
    final block = c.blocks[i];
    if (block == null || block.isEmpty) {
      // A role's view, found once a run for every stage that binds it.
      final role = c.roles[i];
      final want = c.bytes[i];
      if (role != null && role.run == _runs && role.want == want) {
        return role.view!;
      }
      final view = _uniform(host, block, want);
      if (role != null) {
        role
          ..run = _runs
          ..want = want
          ..view = view;
      }
      return view;
    }
    final e = c.entries[i];
    if (e != null) {
      if (e.run == _runs) return e.view;
      final store = _store;
      if (store != null && e.epoch == store.epoch) {
        e.run = _runs;
        return e.view;
      }
    }
    final made = c.entries[i] = _uniformEntry(host, block, c.bytes[i]);
    return made.view;
  }

  /// The entry of [bytes] as a block of [want] bytes, its view written for
  /// this run.
  _UniformView _uniformEntry(UniformRing host, Uint8List? bytes, int want) {
    final key = bytes ?? _noBlock;
    final had = _uniformViews[key];
    _UniformView? at;
    for (var u = had; u != null; u = u.next) {
      if (u.want != want) continue;
      if (u.run == _runs) return u;
      at = u;
      break;
    }
    final store = _store;
    // A block placed for good binds its place again (its bytes never
    // change once made, keepBlocks).
    if (at != null && store != null && at.epoch == store.epoch) {
      return at..run = _runs;
    }
    final Uint8List data;
    if (bytes != null && bytes.length >= want) {
      data = Uint8List.sublistView(bytes, 0, want);
    } else {
      data = Uint8List(want);
      if (bytes != null) data.setRange(0, bytes.length, bytes);
    }
    // A block bound in the run before as well is placed for good: one made
    // for a single frame stays in the ring.
    if (at != null && store != null && at.run == _runs - 1) {
      if (store.place(data) case final view?) {
        return at
          ..view = view
          ..run = _runs
          ..epoch = store.epoch;
      }
    }
    final view = host.emplace(data);
    if (at != null) {
      // A block bound in an earlier run: written to this run's ring again,
      // its entry kept (no map insert for the blocks a still frame binds
      // again).
      return at
        ..view = view
        ..run = _runs
        ..epoch = -1;
    }
    final made = _UniformView(want, view, had)..run = _runs;
    _uniformViews[key] = made;
    return made;
  }

  /// [s] as the engine's sampler, one per distinct state (looked up once per
  /// state object: the plans reuse theirs from frame to frame).
  gpu.McsmSampler _sampler(
    SamplerState s,
  ) => _samplerObjects[s] ??= _samplers.putIfAbsent(
    '${s.minLinear}${s.magLinear}${s.mipLinear}${s.address.join()}'
    '${s.anisotropy}${s.compare}${s.minLod}${s.maxLod}${s.lodBias}${s.border}',
    () => sampler(s),
  );

  /// [shader]'s slots by its interface's lists ([info]'s blocks, textures
  /// and samplers), resolved on first use.
  _ShaderSlots _slotsOf(gpu.Shader shader, ShaderRecord info) {
    final had = _shaderSlots[info];
    if (had != null && identical(had.shader, shader)) return had;
    return _shaderSlots[info] = _ShaderSlots(shader, info);
  }
}

/// What a render pass holds from its last draw: the engine keeps the
/// bindings until they are cleared, and depth, viewport and blend state
/// until they are set again, so a draw sends only what differs.
class _PassState {
  gpu.Shader? _vs, _fs;
  int _vertexSlots = -1;
  final vertex = _Bound(), pixel = _Bound();
  bool? depthWrite;
  gpu.CompareFunction? compare;
  gpu.Viewport? _viewport;
  // Kept: a growable list gives its store up on clear (perf: one per pass).
  final _blends = KeptList<_FixedBlend?>();

  /// The stencil test set last (none: the engine's default, off) and the
  /// reference set last.
  Stencil? _stencil;
  int? stencilRef;

  /// Everything forgotten for a new pass (the runner reuses one state).
  void reset() {
    _vs = _fs = null;
    _vertexSlots = -1;
    vertex.clear();
    pixel.clear();
    depthWrite = null;
    compare = null;
    _viewport = null;
    _blends.clear();
    _stencil = null;
    stencilRef = null;
    forgetVertex();
  }

  /// Whether the draw's shaders and vertex slot count are the last draw's,
  /// so the pass's bindings stand; else they are forgotten (the caller
  /// clears the pass's).
  bool sameShaders(gpu.Shader vs, gpu.Shader? fs, int vertexSlots) {
    if (identical(vs, _vs) &&
        identical(fs, _fs) &&
        vertexSlots == _vertexSlots) {
      return true;
    }
    _vs = vs;
    _fs = fs;
    _vertexSlots = vertexSlots;
    vertex.clear();
    pixel.clear();
    forgetVertex();
    return false;
  }

  /// The vertex views bound last per slot and the index view, while the
  /// pass's bindings stand.
  final _vertexViews = List<gpu.BufferView?>.filled(16, null);
  gpu.BufferView? _index;

  /// Whether [v] differs from the view slot [slot] holds (and takes it).
  bool newVertex(int slot, gpu.BufferView v) {
    final had = _vertexViews[slot];
    if (identical(had, v) ||
        (had != null &&
            identical(had.buffer, v.buffer) &&
            had.offsetInBytes == v.offsetInBytes &&
            had.lengthInBytes == v.lengthInBytes)) {
      return false;
    }
    _vertexViews[slot] = v;
    return true;
  }

  /// Whether [v] differs from the index view bound last (and takes it).
  bool newIndex(gpu.BufferView v) {
    final had = _index;
    if (identical(had, v) ||
        (had != null &&
            identical(had.buffer, v.buffer) &&
            had.offsetInBytes == v.offsetInBytes &&
            had.lengthInBytes == v.lengthInBytes)) {
      return false;
    }
    _index = v;
    return true;
  }

  /// The vertex and index views are not known (cleared, or bound apart).
  void forgetVertex() {
    _vertexViews.fillRange(0, 16, null);
    _index = null;
  }

  /// Whether [v] differs from the viewport set last (and takes it): one
  /// object per distinct viewport (_viewportOf).
  bool newViewport(gpu.Viewport v) {
    if (identical(_viewport, v)) return false;
    _viewport = v;
    return true;
  }

  /// Whether attachment [i]'s blend [b] differs from the one set last (and
  /// takes it): one object per distinct blend (_fixedBlend).
  bool newBlend(int i, _FixedBlend b) {
    while (_blends.length <= i) {
      _blends.add(null);
    }
    if (identical(_blends[i], b)) return false;
    _blends[i] = b;
    return true;
  }

  /// Whether stencil test [s] differs from the one set last (and takes it).
  bool newStencil(Stencil? s) {
    final had = _stencil;
    if (identical(had, s)) return false;
    if (had != null &&
        s != null &&
        had.func == s.func &&
        had.passOp == s.passOp &&
        had.readMask == s.readMask &&
        had.writeMask == s.writeMask) {
      return false;
    }
    _stencil = s;
    return true;
  }
}

/// What a stage bound last per slot (blocks, textures, samplers in its
/// interface's order), for one shader interface.
class _Bound {
  ShaderRecord? _info;
  List<Object?> _last = const [];

  void clear() => _info = null;

  /// The slots for [info], all unbound when [info] is new here (the list
  /// is reused while it is long enough: a pass's shaders change often).
  List<Object?> of(ShaderRecord info) {
    if (identical(info, _info)) return _last;
    _info = info;
    final n = info.blocks.length + info.textures.length + info.samplers.length;
    if (_last.length >= n) {
      // (The first list is const: nothing to clear for no slots.)
      if (n > 0) _last.fillRange(0, n, null);
      return _last;
    }
    return _last = List.filled(n, null);
  }
}

/// A frame role's view in the run that last bound it (FrameRole: its
/// bytes the same for the whole run), shared by every stage that binds
/// the role.
final class _RoleView {
  int run = -1, want = -1;
  gpu.BufferView? view;
}

/// A block's view in a run's uniform ring for [want] bytes, and its views
/// for other sizes (a block is mostly bound at one size: one lookup, no map
/// a block a frame).
final class _UniformView {
  _UniformView(this.want, this.view, this.next);
  final int want;

  /// The block's view in the ring of the run [run] that wrote it, or in
  /// the block store ([epoch]: the store's epoch then).
  gpu.BufferView view;
  int run = -1, epoch = -1;
  final _UniformView? next;
}

/// One shader's slots in its interface's order.
class _ShaderSlots {
  _ShaderSlots(this.shader, ShaderRecord info)
    : uniforms = List.filled(info.blocks.length, null),
      textures = List.filled(info.textures.length, null),
      samplers = List.filled(info.samplers.length, null);
  final gpu.Shader shader;
  final List<gpu.UniformSlot?> uniforms;

  /// A compute stage's storage slots by name, per kind (image, texel
  /// buffer, buffer): the skinning's hundreds of dispatches a frame each
  /// bind two, and the slot cache's keys are names joined with their kind.
  final images = <String, gpu.StorageSlot>{};
  final texels = <String, gpu.StorageSlot>{};
  final buffers = <String, gpu.StorageSlot>{};

  /// A texture's separate-texture or texel-buffer slot, by its type.
  final List<gpu.StorageSlot?> textures;
  final List<gpu.StorageSlot?> samplers;
}

/// The sampler a shader's sampler object gets when the plan names none.
const defaultSampler = SamplerState();
const defaultCompareSampler = SamplerState(compare: 'lessEqual');

final _noBlock = Uint8List(0);

/// A shader's binding slots by kind and name ([_RunnerSlots]).
final class _SlotMaps {
  final uniforms = <String, gpu.UniformSlot>{};
  final textures = <String, gpu.StorageSlot>{};
  final samplers = <int, gpu.StorageSlot>{};
  final texels = <String, gpu.StorageSlot>{};
  final images = <String, gpu.StorageSlot>{};
  final buffers = <String, gpu.StorageSlot>{};
}

/// A texel buffer a pass bound to a slot: its view and format.
final class _TexelBound {
  _TexelBound(this.buffer, this.offset, this.length, this.format);
  gpu.DeviceBuffer buffer;
  int offset, length;
  String format;
}

/// A draw stage's inputs in its shader's interface order: its blocks with
/// the bytes each binds, its textures (and which are texel buffers) and
/// its sampler objects, found once by name. A plan's resources are not
/// changed once made, and the runner's sampler for a state is always the
/// same object, so a kept draw binds from these without a name lookup.
final class _StageInputs {
  _StageInputs(this.runner, this.id, this.info, StageResources res)
    : blocks = [for (final b in info.blocks) res.blocks[b.name]],
      bytes = _bytesOf[info] ??= List.unmodifiable([
        for (final b in info.blocks) b.rows * 16,
      ]),
      textures = [for (final t in info.textures) res.textures[t.name]],
      texel = _texelOf[info] ??= List.unmodifiable([
        for (final t in info.textures)
          t.type == 'textureBuffer' || t.type == 'utextureBuffer',
      ]),
      samplers = [
        for (final (slot, comparison) in info.samplers)
          runner._sampler(
            res.samplers[slot] ??
                (comparison ? defaultCompareSampler : defaultSampler),
          ),
      ];
  final FrameRunner runner;
  final String id;
  final ShaderRecord info;

  /// [bytes] and [texel] by shader: they read only it (perf: two lists
  /// per new draw).
  static final _bytesOf = Expando<List<int>>('stage block bytes');
  static final _texelOf = Expando<List<bool>>('stage texel flags');

  /// The shader's slots, and its textures as resolved in [gen]
  /// (FrameRunner._texGen).
  _ShaderSlots? slots;
  late final resolved = List<gpu.Texture?>.filled(textures.length, null);
  int gen = -1;
  final List<Uint8List?> blocks;
  final List<int> bytes;

  /// Each block's entry among the runner's views (runner_slots.dart
  /// _stageUniform), for blocks of bytes; and its role's view, for frame
  /// roles.
  late final entries = List<_UniformView?>.filled(blocks.length, null);
  late final roles = [
    for (final b in blocks)
      b != null && FrameRole.of(b) != null
          ? runner._roleViews[b] ??= _RoleView()
          : null,
  ];
  final List<TextureRef?> textures;
  final List<bool> texel;
  final List<gpu.McsmSampler> samplers;
}
