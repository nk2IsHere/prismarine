part of 'frame_runner.dart';

/// The runner's compute passes: a translated compute shader bound as the
/// exe binds its own, dispatched directly or from GPU-written arguments.
extension _RunnerCompute on FrameRunner {
  /// Records [c] into [into] when given (a pass the dispatches before it
  /// opened, nothing recorded since), else into a new compute pass; returns
  /// the pass. The pass's dispatches may run together (Metal's concurrent
  /// compute encoder), so a barrier goes before a dispatch that reads or
  /// writes what one since the last barrier wrote, or writes what one read,
  /// and it sees their writes as it would from a pass of its own; the
  /// skinning's hundreds of dispatches, each writing its own mesh's buffer,
  /// run without one between them (a barrier after every dispatch kept the
  /// GPU to one small dispatch at a time). Passes see each other's writes
  /// as the encoders end.
  /// [r]'s view in [state]'s [slot], again while its buffer is the one the
  /// view was made over.
  gpu.BufferView _keptView(_DispatchState state, int slot, BufferRef r) {
    // One per frame in flight: a frame buffer's three copies take turns.
    final at = slot * 3 + _frame;
    final b = _current[r.buffer];
    final had = state.views[at];
    if (had != null && b != null && identical(state.viewOf[at], b)) {
      return had;
    }
    final view = _bufferView(r);
    state
      ..views[at] = view
      ..viewOf[at] = view.buffer;
    return view;
  }

  gpu.ComputePass _dispatch(
    gpu.CommandBuffer cb,
    DispatchPlan c,
    UniformRing host, [
    gpu.ComputePass? into,
  ]) {
    // The shader's lookups once per shader id (the skinning's hundreds of
    // dispatches a frame share one).
    final setup = _computeSetups[c.shader] ?? _computeSetupOf(c.shader);
    final shader = setup.shader, info = setup.info, slots = setup.slots;
    final pipeline = setup.pipeline;
    // A kept dispatch (the same object frame after frame) keeps its
    // inputs in its shader's order and its reads and writes.
    var state = c.runnerState;
    if (state is! _DispatchState ||
        !identical(state.runner, this) ||
        !identical(state.setup, setup)) {
      c.runnerState = state = _DispatchState(
        this,
        setup,
        c,
        _accessOf(c, info),
      );
    }
    final access = state.access;
    final pass = into ?? cb.createComputePass();
    if (into == null) {
      _sinceBarrier.clear();
    } else if (_sinceBarrier.conflicts(access)) {
      pass.barrier();
      _sinceBarrier.clear();
    }
    pass.bindPipeline(pipeline);
    for (var i = 0; i < state.blocks.length; i++) {
      pass.bindUniform(
        slots.uniforms[i] ??= _uniformSlot(shader, info.blocks[i].name),
        _uniform(host, state.blocks[i], state.sizes[i]),
      );
    }
    for (var i = 0; i < state.textures.length; i++) {
      final t = info.textures[i];
      final ref = state.textures[i];
      if (setup.texel[i]) {
        // Two locals, not a record (one per texel bind; perf).
        final gpu.BufferView view;
        final String format;
        if (ref is BufferTexture) {
          // A palette bound by role takes this frame's bytes for it.
          final b = ref.bytes;
          view = _frameInline(
            c.name,
            t.name,
            b.isEmpty ? _frameBlocks[b] ?? b : b,
          );
          format = ref.format;
        } else if (ref is BufferTextureRef) {
          view = _keptView(state, state.storage.length + 1 + i, ref.ref);
          format = ref.ref.format ?? 'R32G32B32A32_FLOAT';
        } else {
          view = _inline(_zeroTexel);
          format = 'R32G32B32A32_FLOAT';
        }
        pass.bindTexelBuffer(
          slots.textures[i] ??= _texelSlot(shader, t.name),
          view,
          _formatOf(format),
        );
        continue;
      }
      pass.bindSeparateTexture(
        slots.textures[i] ??= _textureSlot(shader, t.name),
        _texture(ref, t.type),
      );
    }
    for (var i = 0; i < state.samplers.length; i++) {
      pass.bindSeparateSampler(
        slots.samplers[i] ??= _samplerSlot(shader, info.samplers[i].$1),
        state.samplers[i],
      );
    }
    // By index; a frame buffer's view kept with the dispatch while the
    // buffer is the same (perf: an iterator and a view per binding).
    for (var si = 0; si < state.storage.length; si++) {
      final (name, ref) = state.storage[si];
      switch (ref) {
        case final ImageRef i:
          pass.bindStorageImage(
            slots.images[name] ??= _imageSlot(shader, name),
            _imageView(
              i,
              array: setup.arrays[name] ??= (info.storage[name] ?? '').contains(
                'Array',
              ),
            ),
          );
        case final InlineBuffer b when b.format != null:
          pass.bindTexelBuffer(
            slots.texels[name] ??= _texelSlot(shader, name),
            _storageInline(c.name, name, b.bytes),
            _formatOf(b.format!),
          );
        case final InlineBuffer b:
          pass.bindStorageBuffer(
            slots.buffers[name] ??= _bufferSlot(shader, name),
            _storageInline(c.name, name, b.bytes),
          );
        case final BufferRef r when r.format != null:
          pass.bindTexelBuffer(
            slots.texels[name] ??= _texelSlot(shader, name),
            _keptView(state, si, r),
            _formatOf(r.format!),
          );
        case final BufferRef r:
          pass.bindStorageBuffer(
            slots.buffers[name] ??= _bufferSlot(shader, name),
            _keptView(state, si, r),
          );
      }
    }
    try {
      if (c.indirect case final args?) {
        pass.dispatchIndirect(_keptView(state, state.storage.length, args));
      } else {
        pass.dispatch(c.groups[0], c.groups[1], c.groups[2]);
      }
    } on Exception catch (e) {
      // Reported once per shader; the frame goes on without its output.
      if (_failed.add(c.shader)) warn?.call('S2 dispatch ${c.shader}: $e');
    }
    _sinceBarrier.add(access);
    return pass;
  }

  /// An inline storage buffer's view: bound by role ([FrameRole]; the
  /// skin batch's tables), this frame's bytes for it.
  gpu.BufferView _storageInline(String dispatch, String name, Uint8List b) =>
      b.isEmpty && _frameBlocks[b] != null
      ? _frameInline(dispatch, name, _frameBlocks[b]!)
      : _inline(b);

  /// [shader]'s lookups for its dispatches, made on its first (a closure
  /// at the call made a context for every dispatch).
  _ComputeSetup _computeSetupOf(String id) {
    final shader = assets.shader(id);
    final info = assets.shaderRecord(id)!;
    final sw = Stopwatch()..start();
    final p = _computePipelines[id] ??= gpu.gpuContext.createComputePipeline(
      shader,
    );
    _pipelineMs += sw.elapsedMicroseconds / 1000;
    return _computeSetups[id] = _ComputeSetup(
      shader,
      info,
      p,
      _slotsOf(shader, info),
    );
  }

  /// What [c] reads and writes on the GPU: targets and frame buffers by
  /// name, inline storage by its bytes; a storage binding counts as written
  /// unless the shader declares it read-only. Textures and texel data the
  /// CPU fills (files, constants, inline texels) no dispatch writes.
  _Access _accessOf(DispatchPlan c, ShaderRecord info) {
    final a = _Access(this);
    for (final t in c.resources.textures.values) {
      switch (t) {
        case TargetTexture(:final target):
          a.read(target);
        case BufferTextureRef(:final ref):
          a.read(ref.buffer);
        default:
      }
    }
    if (c.indirect case final args?) a.read(args.buffer);
    for (final MapEntry(key: name, value: ref) in c.resources.storage.entries) {
      final Object key = switch (ref) {
        ImageRef(:final target) => target,
        InlineBuffer(:final bytes) => bytes,
        BufferRef(:final buffer) => buffer,
      };
      if (info.readonlyStorage.contains(name)) {
        a.read(key);
      } else {
        a.write(key);
      }
    }
    return a;
  }
}

/// A dispatch's GPU reads and writes ([_RunnerCompute._accessOf]), or a
/// pass's since its last barrier. Target and buffer names and inline bytes
/// (compared by identity) do not collide.
final class _Access {
  _Access([this.runner]);

  /// The runner whose dispatch this is (null: a pass's own).
  final FrameRunner? runner;
  // Kept collections: cleared per barrier and dispatch (perf: the default
  // ones gave their storage up on each clear).
  final reads = KeptSet<Object>(), writes = KeptSet<Object>();

  /// The same in order, walked by index (a set's walk made an iterator per
  /// dispatch; perf).
  final _readList = KeptList<Object>(), _writeList = KeptList<Object>();

  void read(Object o) {
    if (reads.add(o)) _readList.add(o);
  }

  void write(Object o) {
    if (writes.add(o)) _writeList.add(o);
  }

  void clear() {
    reads.clear();
    writes.clear();
    _readList.clear();
    _writeList.clear();
  }

  /// Whether [next] must wait for these: it reads or writes what these
  /// wrote, or writes what these read.
  bool conflicts(_Access next) {
    final r = next._readList, w = next._writeList;
    for (var i = 0; i < r.length; i++) {
      if (writes.contains(r[i])) return true;
    }
    for (var i = 0; i < w.length; i++) {
      if (writes.contains(w[i]) || reads.contains(w[i])) return true;
    }
    return false;
  }

  void add(_Access a) {
    final r = a._readList, w = a._writeList;
    for (var i = 0; i < r.length; i++) {
      read(r[i]);
    }
    for (var i = 0; i < w.length; i++) {
      write(w[i]);
    }
  }
}

/// What a runner keeps with a dispatch (DispatchPlan.runnerState): its
/// blocks with the bytes each binds, textures and sampler objects in its
/// shader's order, its storage inputs, found once by name, and its reads
/// and writes. A plan's resources are not changed once made.
final class _DispatchState {
  _DispatchState(this.runner, this.setup, DispatchPlan c, this.access)
    : blocks = [for (final b in setup.info.blocks) c.resources.blocks[b.name]],
      sizes = [for (final b in setup.info.blocks) b.rows * 16],
      textures = [
        for (final t in setup.info.textures) c.resources.textures[t.name],
      ],
      samplers = [
        for (final (slot, comparison) in setup.info.samplers)
          runner._sampler(
            c.resources.samplers[slot] ??
                (comparison ? defaultCompareSampler : defaultSampler),
          ),
      ],
      storage = [
        for (final MapEntry(:key, :value) in c.resources.storage.entries)
          (key, value),
      ];
  final FrameRunner runner;
  final _ComputeSetup setup;
  final _Access access;
  final List<Uint8List?> blocks;
  final List<int> sizes;
  final List<TextureRef?> textures;
  final List<gpu.McsmSampler> samplers;
  final List<(String, StorageRef)> storage;

  /// Each frame-buffer binding's view and the buffer it is of, by slot
  /// (the storage bindings, the indirect arguments, then the texel refs)
  /// and frame in flight.
  late final views = List<gpu.BufferView?>.filled(
    (storage.length + 1 + textures.length) * 3,
    null,
  );
  late final viewOf = List<gpu.DeviceBuffer?>.filled(views.length, null);
}

/// A compute shader's lookups for its dispatches: the shader, its
/// interface, pipeline and slots, which of its textures are texel buffers
/// and which storage images arrays.
final class _ComputeSetup {
  _ComputeSetup(this.shader, this.info, this.pipeline, this.slots)
    : texel = [
        for (final t in info.textures)
          t.type == 'textureBuffer' || t.type == 'utextureBuffer',
      ];
  final gpu.Shader shader;
  final ShaderRecord info;
  final gpu.ComputePipeline pipeline;
  final _ShaderSlots slots;
  final List<bool> texel;
  final arrays = <String, bool>{};
}

/// A plan's format name as the engine's format, converted once per name.
gpu.PixelFormat _formatOf(String name) => _formats[name] ??= pixelFormat(name);
final _formats = <String, gpu.PixelFormat>{};
