part of 'frame_runner.dart';

/// The compute passes of the runner. A compute shader is bound as Direct3D
/// 11 binds it and dispatched directly or from GPU-written arguments.
extension _RunnerCompute on FrameRunner {
  /// Returns the view of [r] in the [slot] of [state]. The view is used
  /// again while its buffer is the one that the view was made over.
  gpu.BufferView _keptView(_DispatchState state, int slot, BufferRef r) {
    // One view per frame in flight, since the three copies of a frame buffer
    // take turns.
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

  /// Records [c] into [into] when given, else into a new compute pass. Returns
  /// the pass. [into] is a pass that the dispatches before [c] opened, with
  /// nothing recorded since. The dispatches of a pass may run together on the
  /// concurrent compute encoder of Metal. A barrier therefore goes before a
  /// dispatch that reads or writes what one since the last barrier wrote, or
  /// writes what one read. The dispatch then sees their writes as it would from
  /// a pass of its own. Dispatches that each write their own buffer run without
  /// a barrier between them. Passes see the writes of each other as the
  /// encoders end.
  gpu.ComputePass _dispatch(
    gpu.CommandBuffer cb,
    DispatchPlan c,
    UniformRing host, [
    gpu.ComputePass? into,
  ]) {
    // The lookups of the shader, once per shader id.
    final setup = _computeSetups[c.shader] ?? _computeSetupOf(c.shader);
    final shader = setup.shader, info = setup.info, slots = setup.slots;
    final pipeline = setup.pipeline;
    // A kept dispatch, the same object frame after frame, keeps its inputs
    // in the order of its shader and its reads and writes.
    var state = c.runnerState;
    if (state is! _DispatchState ||
        !identical(state.runner, this) ||
        !identical(state.setup, setup)) {
      // alloc: a dispatch's first run on this runner
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
        // Two locals, not a record per texel bind.
        final gpu.BufferView view;
        final String format;
        if (ref is BufferTexture) {
          // A block bound by role takes the bytes of this frame for it.
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
    // By index. The view of a frame buffer is kept with the dispatch while
    // the buffer is the same.
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
      // Reported once per shader. The frame goes on without its output.
      if (_failed.add(c.shader)) {
        // alloc: once per shader whose dispatch failed
        warn?.call('renderer: dispatch ${c.shader}: $e');
      }
    }
    _sinceBarrier.add(access);
    return pass;
  }

  /// Returns the view of an inline storage buffer. A buffer bound by role
  /// ([FrameRole]) takes the bytes of this frame for it.
  gpu.BufferView _storageInline(String dispatch, String name, Uint8List b) =>
      b.isEmpty && _frameBlocks[b] != null
      ? _frameInline(dispatch, name, _frameBlocks[b]!)
      : _inline(b);

  // alloc-cold: the first dispatch of a shader.
  /// Returns the lookups of the shader [id] for its dispatches, made on its
  /// first dispatch.
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

  // alloc-cold: a dispatch's first run on this runner.
  /// Returns the reads and writes of [c] on the GPU, with targets and frame
  /// buffers by name and inline storage by its bytes. A storage binding
  /// counts as written unless the shader [info] declares it read-only. No
  /// dispatch writes the textures and texel data that the CPU fills, such
  /// as files, constants and inline texels.
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

/// The GPU reads and writes of a dispatch ([_RunnerCompute._accessOf]) or of
/// a pass since its last barrier. Target and buffer names and inline bytes,
/// compared by identity, do not collide.
final class _Access {
  _Access([this.runner]);

  /// The runner of the dispatch, or null for the access of a pass.
  final FrameRunner? runner;
  // Kept collections, cleared per barrier and dispatch.
  final reads = KeptSet<Object>(), writes = KeptSet<Object>();

  /// The same in order, walked by index without an iterator.
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

  /// Returns true when [next] must wait for these accesses. It must wait
  /// when it reads or writes what these wrote, or writes what these read.
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

/// The state that a runner keeps with a dispatch (DispatchPlan.runnerState). It
/// holds the blocks with the bytes that each binds, the textures and sampler
/// objects in the order of the shader, the storage inputs found once by name
/// and the reads and writes. The resources of a plan do not change once made.
final class _DispatchState {
  // alloc-cold: a dispatch's first run on this runner.
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
  final List<gpu.PrismarineSampler> samplers;
  final List<(String, StorageRef)> storage;

  /// The view of each frame-buffer binding and its buffer, by slot and frame
  /// in flight. The slots are the storage bindings, the indirect arguments
  /// and then the texel refs.
  late final views = List<gpu.BufferView?>.filled(
    (storage.length + 1 + textures.length) * 3,
    null,
  );
  late final viewOf = List<gpu.DeviceBuffer?>.filled(views.length, null);
}

/// The lookups of a compute shader for its dispatches. They are the shader,
/// its interface, pipeline and slots, its textures that are texel buffers
/// and its storage images that are arrays.
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

/// Returns the format name of a plan as a format of the engine, converted
/// once per name.
gpu.PixelFormat _formatOf(String name) => _formats[name] ??= pixelFormat(name);
final _formats = <String, gpu.PixelFormat>{};
