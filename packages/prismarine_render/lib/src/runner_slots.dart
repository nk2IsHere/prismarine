part of 'frame_runner.dart';

/// Binding lookups kept across draws and frames. A slot object resolves its
/// name in the engine on first use. Many draws share the constant blocks of
/// a frame, such as the blocks of the camera, the scene and a light group.
/// Each block is written to the uniform ring once per frame and its view is
/// bound again.
extension _RunnerSlots on FrameRunner {
  // One map per kind and shader, looked up by the name itself without a key
  // string or a closure per lookup.
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

  /// Returns [block] as a block of [want] bytes, its declared rows, written
  /// once per frame into [host]. The block is zero-padded when the block of
  /// the plan is shorter.
  gpu.BufferView _uniform(UniformRing host, Uint8List? block, int want) {
    // A frame role binds the bytes of the frame for it (FrameRole).
    final bytes = block != null && block.isEmpty
        ? _frameBlocks[block] ?? block
        : block;
    return _uniformEntry(host, bytes, want).view;
  }

  /// Binds the [i]th block of a stage as [_uniform] does, through the entry
  /// that the stage [c] keeps for a block of bytes. The blocks of a kept draw
  /// then bind without a lookup by block.
  gpu.BufferView _stageUniform(UniformRing host, _StageInputs c, int i) {
    final block = c.blocks[i];
    if (block == null || block.isEmpty) {
      // The view of a role, found once a run for every stage that binds it.
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

  /// Returns the entry of [bytes] as a block of [want] bytes, with its view
  /// written for this run.
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
    // A block placed for good binds its place again, since its bytes do not
    // change once made (keepBlocks).
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
    // A block bound in the run before as well is placed for good. A block
    // made for a single frame stays in the ring.
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
      // A block bound in an earlier run is written to the ring of this run
      // again and its entry is kept.
      return at
        ..view = view
        ..run = _runs
        ..epoch = -1;
    }
    final made = _UniformView(want, view, had)..run = _runs;
    _uniformViews[key] = made;
    return made;
  }

  /// Returns [s] as a sampler of the engine, one per distinct state, looked
  /// up once per state object.
  gpu.McsmSampler _sampler(
    SamplerState s,
  ) => _samplerObjects[s] ??= _samplers.putIfAbsent(
    '${s.minLinear}${s.magLinear}${s.mipLinear}${s.address.join()}'
    '${s.anisotropy}${s.compare}${s.minLod}${s.maxLod}${s.lodBias}${s.border}',
    () => sampler(s),
  );

  /// Returns the slots of [shader] by the blocks, textures and samplers of
  /// its interface [info], resolved on first use.
  _ShaderSlots _slotsOf(gpu.Shader shader, ShaderRecord info) {
    final had = _shaderSlots[info];
    if (had != null && identical(had.shader, shader)) return had;
    return _shaderSlots[info] = _ShaderSlots(shader, info);
  }
}

/// The state that a render pass holds from its last draw. The engine keeps the
/// bindings until they are cleared. It keeps the depth, viewport and blend
/// state until they are set again. A draw sends only what differs.
class _PassState {
  gpu.Shader? _vs, _fs;
  int _vertexSlots = -1;
  final vertex = _Bound(), pixel = _Bound();
  bool? depthWrite;
  gpu.CompareFunction? compare;
  gpu.Viewport? _viewport;
  // A kept list, since a growable list gives its storage up on clear.
  final _blends = KeptList<_FixedBlend?>();

  /// The stencil test and the reference set last. The test is null for the
  /// default of the engine, which is off.
  Stencil? _stencil;
  int? stencilRef;

  /// Forgets everything for a new pass, since the runner reuses one state.
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

  /// Returns true when [vs], [fs] and [vertexSlots] are those of the last
  /// draw and the bindings of the pass stand. Otherwise they are forgotten
  /// and the caller clears those of the pass.
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
  /// bindings of the pass stand.
  final _vertexViews = List<gpu.BufferView?>.filled(16, null);
  gpu.BufferView? _index;

  /// Returns true when [v] differs from the view that [slot] holds. Takes [v].
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

  /// Returns true when [v] differs from the index view bound last. Takes [v].
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

  /// Forgets the vertex and index views after a clear or a bind elsewhere.
  void forgetVertex() {
    _vertexViews.fillRange(0, 16, null);
    _index = null;
  }

  /// Returns true when [v] differs from the viewport set last. Takes [v]. A
  /// distinct viewport is one object (_viewportOf).
  bool newViewport(gpu.Viewport v) {
    if (identical(_viewport, v)) return false;
    _viewport = v;
    return true;
  }

  /// Returns true when the blend [b] of the attachment [i] differs from the
  /// blend set last. Takes [b]. A distinct blend is one object (_fixedBlend).
  bool newBlend(int i, _FixedBlend b) {
    while (_blends.length <= i) {
      _blends.add(null);
    }
    if (identical(_blends[i], b)) return false;
    _blends[i] = b;
    return true;
  }

  /// Returns true when the stencil test [s] differs from the test set last.
  /// Takes [s].
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

/// The bindings of a stage last per slot, with blocks, textures and samplers
/// in the order of its interface, for one shader interface.
class _Bound {
  ShaderRecord? _info;
  List<Object?> _last = const [];

  void clear() => _info = null;

  /// Returns the slots for [info], all unbound when [info] is new here. The
  /// list is reused while it is long enough.
  List<Object?> of(ShaderRecord info) {
    if (identical(info, _info)) return _last;
    _info = info;
    final n = info.blocks.length + info.textures.length + info.samplers.length;
    if (_last.length >= n) {
      // The first list is const and has nothing to clear for no slots.
      if (n > 0) _last.fillRange(0, n, null);
      return _last;
    }
    return _last = List.filled(n, null);
  }
}

/// The view of a frame role (FrameRole) in the run that last bound it,
/// shared by every stage that binds the role. Its bytes are the same for the
/// whole run.
final class _RoleView {
  int run = -1, want = -1;
  gpu.BufferView? view;
}

/// The view of a block in the uniform ring of a run for [want] bytes with its
/// views for other sizes. A block is mostly bound at one size.
final class _UniformView {
  _UniformView(this.want, this.view, this.next);
  final int want;

  /// The view of the block in the ring of the run [run] that wrote it, or in
  /// the block store at the epoch [epoch].
  gpu.BufferView view;
  int run = -1, epoch = -1;
  final _UniformView? next;
}

/// The slots of one shader in the order of its interface.
class _ShaderSlots {
  _ShaderSlots(this.shader, ShaderRecord info)
    : uniforms = List.filled(info.blocks.length, null),
      textures = List.filled(info.textures.length, null),
      samplers = List.filled(info.samplers.length, null);
  final gpu.Shader shader;
  final List<gpu.UniformSlot?> uniforms;

  /// The storage slots of a compute stage by name, per kind of image, texel
  /// buffer or buffer.
  final images = <String, gpu.StorageSlot>{};
  final texels = <String, gpu.StorageSlot>{};
  final buffers = <String, gpu.StorageSlot>{};

  /// The separate-texture or texel-buffer slot of a texture, by its type.
  final List<gpu.StorageSlot?> textures;
  final List<gpu.StorageSlot?> samplers;
}

/// The sampler for a sampler object of a shader when the plan gives none.
const defaultSampler = SamplerState();
const defaultCompareSampler = SamplerState(compare: 'lessEqual');

final _noBlock = Uint8List(0);

/// The binding slots of a shader by kind and name ([_RunnerSlots]).
final class _SlotMaps {
  final uniforms = <String, gpu.UniformSlot>{};
  final textures = <String, gpu.StorageSlot>{};
  final samplers = <int, gpu.StorageSlot>{};
  final texels = <String, gpu.StorageSlot>{};
  final images = <String, gpu.StorageSlot>{};
  final buffers = <String, gpu.StorageSlot>{};
}

/// A texel buffer that a pass bound to a slot, with its view and format.
final class _TexelBound {
  _TexelBound(this.buffer, this.offset, this.length, this.format);
  gpu.DeviceBuffer buffer;
  int offset, length;
  String format;
}

/// The inputs of a draw stage in the order of the interface of its shader. They
/// are its blocks with the bytes that each binds, its textures with the texel
/// buffers among them and its sampler objects, found once by name. The
/// resources of a plan do not change once made. The sampler of the runner for a
/// state is always the same object. A kept draw then binds from these without a
/// name lookup.
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

  /// [bytes] and [texel] by shader, since they depend only on the shader.
  static final _bytesOf = Expando<List<int>>('stage block bytes');
  static final _texelOf = Expando<List<bool>>('stage texel flags');

  /// The slots of the shader and its textures as resolved in [gen]
  /// (FrameRunner._texGen).
  _ShaderSlots? slots;
  late final resolved = List<gpu.Texture?>.filled(textures.length, null);
  int gen = -1;
  final List<Uint8List?> blocks;
  final List<int> bytes;

  /// The entry of each block of bytes among the views of the runner
  /// (runner_slots.dart _stageUniform). A frame role has the view of its
  /// role.
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
