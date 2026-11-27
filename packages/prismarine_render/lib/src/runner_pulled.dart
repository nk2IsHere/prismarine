part of 'frame_runner.dart';

/// The per-frame scratch and buffers of a pulled pass, kept by the runner per
/// pass. The passes of a frame are prepared before the GPU runs the first one.
/// No pass may share the scratch of another.
class _PulledFrame {
  // alloc-cold: once per pulled pass.
  _PulledFrame();

  final instances = _Bytes(), objects = _Bytes(), materials = _Bytes();
  final clusters = _Bytes(), bases = _Bytes(), args = _Bytes();

  /// The mesh boxes of the rows of a cascade pass, 8 floats per instance.
  final boxes = _Bytes();

  /// The block of each object row as the draws bind it, read again each frame
  /// for a role. It also holds the part of the rows as last made ([_KeptRows]).
  final objectSources = KeptList<Uint8List>();
  _KeptRows? kept;

  /// The storage of [kept], filled again when the rows change, also while
  /// [kept] is null.
  final keptStore = _KeptRows();
  final objectAt = KeptMap<Uint8List, int>.identity(),
      materialAt = KeptMap<Uint8List, int>.identity();
  final indexCounts = KeptList<int>();

  /// The state of a prepare while its draws are added (_pulledAdd). It is
  /// kept from frame to frame and cleared with its storage kept.
  final rest = KeptList<DrawPlan>();

  /// With [PulledLayout.keepOrder], the buckets made before each draw of
  /// [rest]: it is drawn after that many buckets, in the plan's order.
  final restAfter = KeptList<int>();
  final why = KeptMap<String, int>();
  final buckets = KeptMap<Object, _PulledBucket>();

  /// The last bucket made per key, taken again while it holds.
  final bucketPool = KeptMap<Object, _PulledBucket>();

  /// With [PulledLayout.keepOrder], the key of the last draw added and the
  /// key of its run's bucket: the pulled form of the run's first draw.
  Object? lastKey, lastRun;
  bool keepable = true;
  int instanceCount = 0;
  Uint8List? camera, cameraSource;
  final slots = [
    _PulledFrameBuffers(),
    _PulledFrameBuffers(),
    _PulledFrameBuffers(),
  ];

  /// The buckets in cluster order and their base words.
  final ranges = KeptList<_PulledBucket>();
  var words = Uint32List(0);
  var wordBytes = Uint8List(0);
}

/// Six planes that keep every cluster: no normal, a far-off distance.
final _keepAllPlanes = Float32List(24)
  ..[3] = 1e30
  ..[7] = 1e30
  ..[11] = 1e30
  ..[15] = 1e30
  ..[19] = 1e30
  ..[23] = 1e30;

/// The views of a pulled bucket for its stages ([_RunnerPulled._pulledStage]),
/// the clusters, instances, objects and materials.
final _stageViews = List<gpu.BufferView?>.filled(4, null);

final _emptyObject = Uint8List(16);

/// The zeros that pad an object row, added by copy and not changed.
final _zero16 = Uint8List(16);

/// The pulled buffers of a frame, kept and overwritten. One set exists per
/// frame in flight, as the runner keeps the plan buffers of three frames.
class _PulledFrameBuffers {
  gpu.DeviceBuffer? instances, objects, materials, clusters, args, bases;
  gpu.DeviceBuffer? boxes;

  /// A view of the whole of [clusters].
  gpu.BufferView? clusterView;

  /// The kinds of the buffers that [put] fills.
  static const instancesKind = 0, objectsKind = 1, argsKind = 2;
  static const basesKind = 3, materialsKind = 4, boxesKind = 5;

  gpu.DeviceBuffer? _of(int kind) => switch (kind) {
    instancesKind => instances,
    objectsKind => objects,
    argsKind => args,
    basesKind => bases,
    materialsKind => materials,
    _ => boxes,
  };

  void _setOf(int kind, gpu.DeviceBuffer b) => switch (kind) {
    instancesKind => instances = b,
    objectsKind => objects = b,
    argsKind => args = b,
    basesKind => bases = b,
    materialsKind => materials = b,
    _ => boxes = b,
  };

  /// Puts the first [length] of [bytes] into the buffer of [kind], grown
  /// when it is too small. Returns the view of the bytes.
  gpu.BufferView put(int kind, Uint8List bytes, int length) {
    var b = _of(kind);
    final want = length < 16 ? 16 : length;
    if (b == null || b.sizeInBytes < want) {
      gpu.GpuMemory.tag = 'buffer.pulledRows';
      b = gpu.gpuContext.createDeviceBuffer(
        gpu.StorageMode.hostVisible,
        want * 2,
      );
      gpu.GpuMemory.tag = null;
      _setOf(kind, b);
    }
    b.overwrite(ByteData.sublistView(bytes, 0, length));
    return gpu.BufferView(b, offsetInBytes: 0, lengthInBytes: want);
  }
}

/// Returns the key of the part of the state of a draw that its bucket
/// shares. The key holds the fields, since the builder makes a state object
/// per draw.
String _stateKey(DrawState s) =>
    '${s.cull}|${s.frontCounterClockwise}|${s.depthTest}|${s.depthWrite}|'
    '${s.depthFunc}|${s.topology}|${s.depthBias}|${s.slopeScaledDepthBias}|'
    '${s.depthBiasClamp}|'
    '${s.stencil == null ? '' : '${s.stencil!.func},${s.stencil!.passOp},${s.stencil!.readMask},${s.stencil!.writeMask}'}|'
    '${[for (final b in s.blends) '${b.enabled}${b.color}${b.alpha}'].join(';')}';

/// Returns a texture reference as a bucket compares it. A reference is
/// compared by its target, since a plan read from its files makes a
/// reference object per draw. Its bytes are compared by identity, since
/// blocks and texels are kept objects.
Object _textureKey(TextureRef ref) => switch (ref) {
  FileTexture(:final stem, :final srgb) => 'f:$stem:$srgb',
  final TargetTexture t =>
    't:${t.target}:${t.mip}:${t.mips}:${t.layer}:${t.layers}:${t.srgb}',
  final BufferTexture b => b.bytes,
  final ConstantTexture c => c.texel,
  final BufferTextureRef r =>
    'r:${r.ref.buffer}:${r.ref.offset}:${r.ref.size}:${r.ref.format}',
};

final _pulledOnly = envVar('PULLED_ONLY')?.split(',');

String _samplerKey(SamplerState s) =>
    '${s.minLinear}${s.magLinear}${s.mipLinear}${s.address.join()}'
    '${s.anisotropy}${s.compare}${s.minLod}${s.maxLod}${s.lodBias}${s.border}';

/// The storage names as the pulled stage matches them, `Raw<Name>` lower-cased
/// without `raw`. It also holds the names of the pool streams as `pool<name>`,
/// made once.
final _storageKeys = <String, String>{};
final _poolKeys = <String, String>{};

/// The storage names of each stage in order ([_RunnerPulled._pulledStage]).
final _storageNames = Expando<List<String>>('pulled storage names');

/// Returns the stream of [pool] whose name, as `pool<name>` lower-cased
/// without underscores, is [n].
gpu.BufferView _poolStream(_PoolGpu pool, String n, String id, String name) =>
    pool.byStorage[n] ?? (pool.byStorage[n] = _findStream(pool, n, id, name));

// alloc-cold: the first lookup of a stream of a pool.
gpu.BufferView _findStream(_PoolGpu pool, String n, String id, String name) {
  for (final key in pool.streams.keys) {
    final k = _poolKeys[key] ??= 'pool${key.replaceAll('_', '').toLowerCase()}';
    if (k == n) return pool.streams[key]!;
  }
  throw StateError('$id: no pool stream $name');
}

extension _RunnerPulled on FrameRunner {
  /// Returns [d] in pulled form, made on its first frame and kept with it.
  _PulledDraw _pulledOf(DrawPlan d) {
    final had = _pulledForms[d];
    if (had != null && !(had.scene?.dead ?? false)) return had;
    return _pulledForms[d] = _makePulled(d);
  }

  // alloc-cold: a draw's first pulled form or load.
  /// Why draw [d] has no pulled form, from the draw alone (a cooked batch
  /// apart); null when it has one.
  String? _refusal(DrawPlan d) {
    final p = pulled!;
    return switch (d.geometry) {
      // A skinned batch reads the skinning output of the frame, one buffer
      // for all its streams.
      DrawMeshGeometry(streams: final st)
          when st.isNotEmpty &&
              st.values.map((e) => e.$1.buffer).toSet().length != 1 =>
        'skinned',
      DrawMeshGeometry(indirect: final i) when i != null => 'indirect',
      // The place of a blended draw in the pass changes the picture. Without
      // keepOrder it keeps its record after the pulled buckets (opaque draws
      // test depth equal); with it, the buckets keep the plan's order.
      DrawMeshGeometry()
          when !p.layout.keepOrder && d.state.blends.any((b) => b.enabled) =>
        'blended',
      DrawMeshGeometry() when !p.shaders.hasShader(_pulledVertexOf(p, d)) =>
        'no pulled vertex',
      DrawMeshGeometry()
          when d.pixel != null && !p.shaders.hasShader(_pulledPixelOf(p, d)!) =>
        'no pulled pixel',
      DrawMeshGeometry()
          when _pulledOnly != null &&
              !_pulledOnly!.any((t) => d.label.contains(t)) =>
        'not chosen',
      DrawMeshGeometry() => null,
      _ => 'not a mesh',
    };
  }

  // alloc-cold: a draw's first load.
  /// Whether draw [d] of a pulled pass draws in pulled form: it has one and
  /// its batch is cooked. Its loads then skip what only its record reads,
  /// the plain programs and the material textures' files.
  bool _drawsPulled(DrawPlan d) {
    final p = pulled;
    final g = d.geometry;
    if (p == null || g is! DrawMeshGeometry || _refusal(d) != null) {
      return false;
    }
    return p.batch(
          g.mesh,
          g.firstIndex,
          g.indexCount,
          shadow: g.ibuffer == 1,
        ) !=
        null;
  }

  // The miss path is a method of its own. An inline closure that captures
  // [d] would allocate a context on every call.
  // alloc-cold: a draw's first pulled form.
  _PulledDraw _makePulled(DrawPlan d) {
    _pulledStats.made++;
    final p = pulled!;
    final layout = p.layout, instanceRow = layout.instanceRow;
    final g = d.geometry;
    final reason = _refusal(d);
    if (reason != null) return _PulledDraw.refused(reason);
    g as DrawMeshGeometry;
    // The indices of a shadow batch are those of the shadow index buffer of
    // the mesh.
    final found = p.batch(
      g.mesh,
      g.firstIndex,
      g.indexCount,
      shadow: g.ibuffer == 1,
      scene: _warm.pulledScene,
    );
    if (found == null) return _PulledDraw.refused('not cooked');
    final (scene, batch) = found;
    // The arrays of the material inputs and the layer of each texture.
    final arrays = <String, gpu.Texture>{};
    final layers = <int>[];
    var arrayKey = '';
    for (final MapEntry(:key, :value) in d.pixelResources.textures.entries) {
      final n = layout.materialTextureSlot(key);
      if (n < 0) continue;
      while (layers.length <= n) {
        layers.add(0);
      }
      // A constant input, such as a material's default black, is a constant
      // array of one layer: its texel samples as its 2D form does.
      if (value is ConstantTexture) {
        arrays[key] = _texture(value, 'texture2DArray');
        arrayKey += '$key=${value.format}:${value.texel.join(',')};';
        continue;
      }
      if (value is! FileTexture) continue;
      final at = scene.scene.textureAt(value.stem);
      if (at == null) {
        // A texture that no array of the scene holds (a swapped texture, or
        // another scene's) is an array of its own: its plain texture viewed
        // as one layer, sampled as its 2D form is.
        if (!assets.hasTexture(value.stem)) continue;
        arrays[key] = _fileArrays[value] ??= () {
          final t = _texture(value, 'texture2D');
          // alloc: the first pulled bind of a texture outside the arrays
          return t.makeView(
            baseMipLevel: 0,
            mipLevelCount: t.mipLevelCount,
            baseLayer: 0,
            layers: 1,
            textureType: gpu.TextureType.texture2DArray,
          );
        }();
        arrayKey += '$key=file:${value.stem}:${value.srgb};';
        continue;
      }
      final a = scene.scene.arrays[at.$1];
      arrays[key] = scene.textures.texture(a.file, srgb: value.srgb);
      layers[n] = at.$2;
      arrayKey += '$key=${a.file}:${value.srgb};';
    }
    // Every material input that the pulled pixel stage declares needs a
    // cooked array. A swapped texture or the texture of another scene may
    // have none. A merged program declares the inputs of all its draws: one
    // that this draw does not have samples the zero stand-in, unread.
    final merged = p.merged[d.pixel];
    final pixelId = _pulledPixelOf(p, d);
    final pixel = pixelId == null ? null : p.shaders.shaderRecord(pixelId);
    for (final t in pixel?.textures ?? const <TextureSlot>[]) {
      if (layout.isMaterialTexture(t.name) && !arrays.containsKey(t.name)) {
        if (merged == null) return _PulledDraw.refused('texture not cooked');
        arrays[t.name] = _texture(null, 'texture2DArray');
        arrayKey += '${t.name}=unread;';
      }
    }
    // A merged draw's header comes first, a uvec4.
    final head = merged == null ? 0 : 16;
    final layerBytes = Uint8List((head + layers.length * 4 + 15) & ~15);
    final lb = layerBytes.buffer.asByteData();
    if (merged != null) {
      lb
        ..setUint32(0, merged.surface, Endian.little)
        ..setUint32(4, merged.flags, Endian.little);
    }
    for (var i = 0; i < layers.length; i++) {
      lb.setUint32(head + i * 4, layers[i], Endian.little);
    }
    // The instance row holds the bytes of the instance block with the
    // texcoord transforms at identity, since the cooked UVs carry them. The
    // range of the batch follows.
    final row = ByteData(instanceRow.stride);
    final ib = d.vertexResources.blocks[layout.instanceBlock];
    final ibytes = ib == null || ib.isEmpty ? null : ib;
    if (ibytes != null) {
      row.buffer.asUint8List().setRange(
        0,
        ibytes.length.clamp(0, instanceRow['object']),
        ibytes,
      );
    }
    for (var t = 0; t < layout.uvTransforms.length; t++) {
      final at = instanceRow[layout.uvTransforms[t]];
      row
        ..setFloat32(at, 0, Endian.little)
        ..setFloat32(at + 4, 0, Endian.little)
        ..setFloat32(at + 8, 1, Endian.little)
        ..setFloat32(at + 12, 1, Endian.little);
    }
    // The output of a skinned batch has its first word, its stride in words
    // and its normal count, 12 bytes and 4 per normal. It has no sphere test,
    // since its bind-pose sphere does not hold the pose and the builder
    // culled it.
    final skin = g.streams.isEmpty
        ? null
        : g.streams.values.reduce((a, b) => a.$1.offset <= b.$1.offset ? a : b);
    for (var k = 0; k < 4; k++) {
      row.setFloat32(
        instanceRow['sphere'] + k * 4,
        skin != null && k == 3 ? -1 : batch.sphere[k],
        Endian.little,
      );
    }
    if (skin case (final ref, final stride, _)) {
      row
        ..setUint32(instanceRow['skinOutput'], ref.offset ~/ 4, Endian.little)
        ..setUint32(
          instanceRow['flags'],
          (stride ~/ 4) << _skinStrideShift |
              ((stride - 12) ~/ 4) << _skinNormalsShift,
          Endian.little,
        );
    }
    row
      ..setUint32(instanceRow['firstIndex'], batch.firstIndex, Endian.little)
      ..setUint32(instanceRow['indexCount'], batch.indexCount, Endian.little)
      ..setUint32(instanceRow['baseVertex'], batch.baseVertex, Endian.little);
    final key = (
      _pulledVertexOf(p, d),
      pixelId,
      skin?.$1.buffer,
      scene.dir,
      batch.pool,
      d.stencilRef,
      _stateKey(d.state),
      d.viewport.join(','),
      arrayKey,
      // The bucket binds the samplers and frame resources of its first draw;
      // a merged draw's by the merged program's slots.
      merged == null
          ? [
              for (final res in [d.vertexResources, d.pixelResources])
                for (final MapEntry(:key, :value) in res.samplers.entries)
                  '$key:${_samplerKey(value)}',
            ].join(';')
          : [
              for (final (own, slots) in [
                (d.vertexResources, merged.vertexSamplers),
                (d.pixelResources, merged.pixelSamplers),
              ])
                for (final MapEntry(:key, :value) in slots.entries)
                  '$key:${_samplerKey(own.samplers[value] ?? defaultSampler)}',
            ].join(';'),
      _IdentityKey([
        for (final res in [d.vertexResources, d.pixelResources]) ...[
          for (final MapEntry(:key, :value) in res.blocks.entries)
            if (!layout.rowBlocks.contains(key)) ...[key, value],
          for (final MapEntry(:key, :value) in res.textures.entries)
            if (!layout.isMaterialTexture(key)) ...[key, _textureKey(value)],
        ],
      ]),
    );
    return _PulledDraw(
      key,
      scene,
      batch,
      arrays,
      layerBytes,
      row.buffer.asUint8List(),
    );
  }

  /// Makes the pulled frame of [draws], the draws of one render pass, before
  /// the pass begins. It makes their rows, the cluster range of each bucket
  /// and the culling dispatch into [cb] that fills the ranges and the
  /// indirect draws of the buckets. A draw is pulled when its mesh batch is
  /// cooked, its programs have pulled forms and it reads no skinning output
  /// or indirect arguments. The other draws stay for the own records of the
  /// plan. Returns null when no draw is pulled.
  _PulledPrepared? _pulledPrepare(
    gpu.CommandBuffer cb,
    String pass,
    List<DrawPlan> draws,
    UniformRing host,
    RowSet? rows,
  ) {
    final at = _clock.elapsedMicroseconds;
    try {
      return _pulledPrepareTimed(cb, pass, draws, host, rows);
    } finally {
      _pulledStats.add(_clock.elapsedMicroseconds - at, warn);
    }
  }

  _PulledPrepared? _pulledPrepareTimed(
    gpu.CommandBuffer cb,
    String pass,
    List<DrawPlan> draws,
    UniformRing host,
    RowSet? rows,
  ) {
    // A pass whose rows carry bounds is culled per cascade
    // (runner_cascades.dart). Its rows come first in [draws].
    final bounds = rows?.bounds;
    final rowCount = rows?.plans.length ?? 0;

    // alloc: a pulled pass's first run
    final f = _pulledFrames[pass] ??= _PulledFrame();
    f.boxes.reset();
    final rest = f.rest..clear();
    final restAfter = f.restAfter..clear();
    final why = f.why..clear();
    final buckets = f.buckets..clear();
    f
      ..lastKey = null
      ..lastRun = null;
    f.instances.reset();
    f.objects.reset();
    f.materials.reset();
    f.clusters.reset();
    f.objectAt.clear();
    f.materialAt.clear();
    f.objectSources.clear();
    final indexCounts = f.indexCounts..clear();
    f
      ..keepable = true
      ..instanceCount = 0
      ..camera = null
      ..cameraSource = null;

    // The part of the rows as the last frame made it, while the rows of the
    // reader are the same draws. Only the bytes of the objects are read
    // again, since the block of a moving object is a role.
    final kept = f.kept;
    if (rows != null && kept != null && identical(kept.plans, rows.plans)) {
      kept.restore(
        pulled!.layout.objectRow,
        f,
        buckets,
        rest,
        restAfter,
        why,
        indexCounts,
        _frameBlocks,
      );
      f
        ..instanceCount = kept.instanceCount
        ..camera = kept.camera == null
            ? null
            : _frameBlocks[kept.camera!] ?? kept.camera;
    } else {
      for (var i = 0; i < rowCount; i++) {
        _pulledAdd(f, draws, i, bounds, rowCount);
      }
      f.kept = rows != null && f.keepable
          ? f.keptStore.take(
              f,
              rows.plans,
              buckets,
              rest,
              restAfter,
              why,
              f.instanceCount,
              f.cameraSource,
            )
          : null;
    }
    for (var i = rowCount; i < draws.length; i++) {
      _pulledAdd(f, draws, i, bounds, rowCount);
    }
    final instanceCount = f.instanceCount;
    final camera = f.camera;
    if (buckets.isEmpty || (camera == null && bounds == null)) return null;
    if (FrameRunner.trace) {
      _tracePulled(instanceCount, buckets.length, rest, why);
    }
    // The cluster range of each bucket, on a 256-byte boundary for the
    // offset alignment of Metal, as many clusters as its instances have. The
    // bases and the arguments of the indirect draws start with their counts
    // at zero. The ranges are kept per pass.
    final ranges = f.ranges..clear();
    final bases = f.bases..reset();
    final args = f.args..reset();
    var next = 0;
    for (final b in buckets.values) {
      b.scene.lastRun = _runs;
      next = (next + 31) & ~31;
      ranges.add(b..start = next);
      bases.addUint32Pair(next, 0);
      args
        ..addUint32Pair(192, 0)
        ..addUint32Pair(0, 0);
      // A cascade row may draw into every cascade.
      if (bounds != null) b.clusters *= _cascadeCount;
      next += b.clusters;
    }
    // The bases, a uint each. The pairs above hold one in their first. The
    // words go through the own data view of the bases.
    if (f.words.length < buckets.length) {
      // alloc: more buckets than any frame before
      f.words = Uint32List(buckets.length * 2);
      // alloc: more buckets than any frame before
      f.wordBytes = f.words.buffer.asUint8List();
    }
    final words = f.words, data = bases._data;
    for (var i = 0; i < buckets.length; i++) {
      words[i] = data.getUint32(i * 8, Endian.little);
    }
    final baseWords = f.wordBytes;
    final slot = f.slots[_runs % 3];
    final instanceView = slot.put(
      _PulledFrameBuffers.instancesKind,
      f.instances.bytes,
      f.instances.length,
    );
    final objectView = slot.put(
      _PulledFrameBuffers.objectsKind,
      f.objects.bytes,
      f.objects.length,
    );
    final argsView = slot.put(
      _PulledFrameBuffers.argsKind,
      args.bytes,
      args.length,
    );
    final basesView = slot.put(
      _PulledFrameBuffers.basesKind,
      baseWords,
      buckets.length * 4,
    );
    final clusterBytes = next * 8;
    var clusters = slot.clusters;
    // The view of a bucket is rounded up to 256 bytes past its last cluster.
    if (clusters == null || clusters.sizeInBytes < clusterBytes + 256) {
      gpu.GpuMemory.tag = 'buffer.pulledRows';
      clusters = slot.clusters = gpu.gpuContext.createDeviceBuffer(
        gpu.StorageMode.devicePrivate,
        clusterBytes * 2 + 256,
      );
      gpu.GpuMemory.tag = null;
    }
    final materialView = slot.put(
      _PulledFrameBuffers.materialsKind,
      f.materials.bytes,
      f.materials.length,
    );
    // One view per cluster buffer.
    var clusterView = slot.clusterView;
    if (clusterView == null || !identical(clusterView.buffer, clusters)) {
      // alloc: a new cluster buffer
      clusterView = slot.clusterView = gpu.BufferView(
        clusters,
        offsetInBytes: 0,
        lengthInBytes: clusters.sizeInBytes,
      );
    }
    if (bounds != null) {
      _cascadeCull(cb, host, f, slot, rows!.params!, instanceCount, (
        objectView,
        instanceView,
        argsView,
        clusterView,
        basesView,
      ));
    } else {
      // The cull takes the planes of the camera, from the view-projection of
      // the camera block as the builder computes them. It also takes the
      // instance count.
      final planes = pulled!.layout.unculled.contains(pass)
          ? _keepAllPlanes
          : pulled!.layout.frustumPlanes(
              Float32List.sublistView(camera!, 0, 64),
            );
      final cull = ByteData(112);
      for (var i = 0; i < 24; i++) {
        cull.setFloat32(i * 4, planes[i], Endian.little);
      }
      cull.setUint32(96, instanceCount, Endian.little);
      final shader = pulled!.shaders.shader(_pulledCull);
      final pipeline = _computePipelines[_pulledCull] ??= gpu.gpuContext
          .createComputePipeline(shader);
      final compute = cb.createComputePass()..bindPipeline(pipeline);
      compute
        ..bindUniform(
          _uniformSlot(shader, 'BufferPulledCull'),
          _uniform(host, cull.buffer.asUint8List(), 112),
        )
        ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledObjects'), objectView)
        ..bindStorageBuffer(
          _bufferSlot(shader, 'RawPulledInstances'),
          instanceView,
        )
        ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledArgs'), argsView)
        ..bindStorageBuffer(
          _bufferSlot(shader, 'RawPulledClusters'),
          clusterView,
        )
        ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledBuckets'), basesView)
        ..dispatch((instanceCount + 63) ~/ 64);
    }
    return _PulledPrepared(
      rest,
      pulled!.layout.keepOrder ? restAfter : null,
      ranges,
      instanceView,
      objectView,
      materialView,
      argsView,
      clusters,
    );
  }

  // alloc-cold: PRISMARINE_RENDER_TRACE runs only.
  void _tracePulled(int draws, int buckets, List<DrawPlan> rest, Object why) =>
      warn?.call(
        'renderer: pulled: $draws draws in $buckets buckets, '
        '${rest.length} left to their records $why',
      );

  /// Records the buckets of [p] into [pass], one indirect draw each of the
  /// clusters that the culling kept.
  void _pulledRecord(gpu.RenderPass pass, _PulledPrepared p, UniformRing host) {
    for (var i = 0; i < p.ranges.length; i++) {
      _pulledRecordOne(pass, p, i, host);
    }
  }

  /// Records bucket [i] of [p] into [pass].
  void _pulledRecordOne(
    gpu.RenderPass pass,
    _PulledPrepared p,
    int i,
    UniformRing host,
  ) {
    final ranges = p.ranges;
    {
      final b = ranges[i], start = b.start;
      if (b.clusters == 0) return;
      _pulledBucket(
        pass,
        b,
        host,
        b.view(
          b.clusterViews,
          p.clusters,
          start * 8,
          ((b.clusters * 8 + 255) & ~255).clamp(
            8,
            p.clusters.sizeInBytes - start * 8,
          ),
        ),
        b.view(b.argViews, p.args.buffer, b.index * 16, 16),
        p.instances,
        p.objects,
        p.materials,
      );
    }
  }

  void _pulledBucket(
    gpu.RenderPass pass,
    _PulledBucket b,
    UniformRing host,
    gpu.BufferView clusters,
    gpu.BufferView args,
    gpu.BufferView instances,
    gpu.BufferView objects,
    gpu.BufferView materials,
  ) {
    final p = pulled!;
    final d = b.first;
    // Kept with the first draw of the bucket, since a kept draw is the same
    // object from frame to frame.
    final cache = _cacheOf(d);
    if (cache.pulledFixed == null && _Warm.on) {
      _warm.learn(_pulledVertexOf(p, d), pulled: true);
    }
    final setup = cache.pulled ??= _pulledSetup(p, d);
    // alloc: the first draw of a bucket
    final fixed = cache.pulledFixed ??= _DrawFixed(d, setup);
    final vs = setup.vs, fs = setup.fs!, pipeline = setup.pipeline;
    final pool = b.scene.pool(b.pool);
    pass
      ..clearBindings()
      ..bindPipeline(pipeline)
      ..setCullMode(fixed.cull)
      ..setWindingOrder(fixed.winding)
      ..setPrimitiveType(gpu.PrimitiveType.triangle)
      ..setDepthWriteEnable(fixed.depthWrite)
      ..setDepthCompareOperation(fixed.compare)
      ..setStencilConfig(fixed.stencilConfig)
      ..setViewport(fixed.viewport);
    if (d.state.stencil != null) pass.setStencilReference(d.stencilRef);
    for (var i = 0; i < fixed.blends.length; i++) {
      final f = fixed.blends[i];
      pass.setColorBlendEnable(f.blend.enabled, colorAttachmentIndex: i);
      if (f.equation case final e?) {
        pass.setColorBlendEquation(e, colorAttachmentIndex: i);
      }
    }
    // The views go through fields, not a record per stage.
    _stageViews
      ..[0] = clusters
      ..[1] = instances
      ..[2] = objects
      ..[3] = materials;
    final v = _pulledVertexOf(p, d), f = _pulledPixelOf(p, d);
    _pulledStage(pass, host, b, pool, d, vs, v, d.vertexResources);
    if (f != null) {
      _pulledStage(pass, host, b, pool, d, fs, f, d.pixelResources);
    }
    pass.drawIndirect(args);
  }

  // alloc-cold: the first draw of a bucket, or a warm-up.
  /// Returns the shaders and pipeline of the draw of a pulled bucket.
  _DrawSetup _pulledSetup(Pulled p, DrawPlan d) {
    final v = _pulledVertexOf(p, d), f = _pulledPixelOf(p, d);
    final vs = p.shaders.shader(v);
    final fs = f == null ? assets.shader(_depthOnly(d)) : p.shaders.shader(f);
    final pipeline = _pipelines[('pulled', v, f)] ??= gpu.gpuContext
        .createRenderPipeline(
          vs,
          fs,
          // A pulled vertex has no inputs. Its place in its cluster is
          // gl_VertexIndex.
          vertexLayout: const gpu.VertexLayout(buffers: []),
        );
    return (
      vs: vs,
      fs: fs,
      pipeline: pipeline,
      mesh: null,
      slots: const [],
      inlineVertices: null,
    );
  }

  /// Binds the inputs of the stage [id] with [shader] for the draw [d] of
  /// the bucket [b].
  void _pulledStage(
    gpu.RenderPass pass,
    UniformRing host,
    _PulledBucket b,
    _PoolGpu pool,
    DrawPlan d,
    gpu.Shader shader,
    String id,
    StageResources res,
  ) {
    final p = pulled!;
    final views = _stageViews;
    final clusters = views[0]!, instances = views[1]!;
    final objects = views[2]!, materials = views[3]!;
    final info = p.shaders.shaderRecord(id)!;
    // By index, with the storage names listed once per stage.
    final blocks = info.blocks;
    for (var k = 0; k < blocks.length; k++) {
      final block = blocks[k];
      pass.bindUniform(
        _uniformSlot(shader, block.name),
        _uniform(host, res.blocks[block.name], block.rows * 16),
      );
    }
    // alloc: the first bind of a stage of a pulled program
    final names = _storageNames[info] ??= info.storage.keys.toList(
      growable: false,
    );
    for (var k = 0; k < names.length; k++) {
      final name = names[k];
      // `Raw<Name>` as the cooked programs declare them.
      // alloc: the first bind of a storage name
      final n = _storageKeys[name] ??= name.toLowerCase().replaceFirst(
        'raw',
        '',
      );
      final view = switch (n) {
        'pulledclusters' => clusters,
        'poolindices' => pool.indices,
        'pulledinstances' => instances,
        'pulledobjects' => objects,
        'pulledmaterials' => materials,
        'skinout' => _bufferView(
          BufferRef(
            (d.geometry as DrawMeshGeometry).streams.values.first.$1.buffer,
          ),
        ),
        _ when n.startsWith('pool') => _poolStream(pool, n, id, name),
        _ => throw StateError('$id: unknown storage $name'),
      };
      pass.bindStorageBuffer(_bufferSlot(shader, name), view);
    }
    final textures = info.textures;
    for (var k = 0; k < textures.length; k++) {
      final t = textures[k];
      if (p.layout.isMaterialTexture(t.name)) {
        final tex = b.arrays[t.name];
        if (tex == null) {
          throw StateError('$id: no array for ${t.name}');
        }
        pass.bindSeparateTexture(_textureSlot(shader, t.name), tex);
        continue;
      }
      // A frame texture or texel buffer, as the own record of the draw binds
      // it.
      final ref = res.textures[t.name];
      if (t.type.contains('Buffer')) {
        // Two locals, not a record per texel bind.
        final gpu.BufferView view;
        final String format;
        if (ref is BufferTexture) {
          final bytes = ref.bytes;
          view = _inline(bytes.isEmpty ? _frameBlocks[bytes] ?? bytes : bytes);
          format = ref.format;
        } else if (ref is BufferTextureRef) {
          view = _bufferView(ref.ref);
          format = ref.ref.format ?? 'R32G32B32A32_FLOAT';
        } else {
          view = _inline(_zeroTexel);
          format = 'R32G32B32A32_FLOAT';
        }
        pass.bindTexelBuffer(
          _texelSlot(shader, t.name),
          view,
          _formatOf(format),
        );
        continue;
      }
      pass.bindSeparateTexture(
        _textureSlot(shader, t.name),
        _texture(ref, t.type),
      );
    }
    final samplers = info.samplers;
    // A merged program's slots are named by their texture; the draw's own
    // slot holds its sampler.
    final merged = p.merged[d.pixel];
    final own = merged == null
        ? null
        : id == merged.pixel
        ? merged.pixelSamplers
        : merged.vertexSamplers;
    for (var k = 0; k < samplers.length; k++) {
      final (slot, compare) = samplers[k];
      pass.bindSeparateSampler(
        _samplerSlot(shader, slot),
        _sampler(
          res.samplers[own == null ? slot : own[slot]] ??
              (compare ? defaultCompareSampler : defaultSampler),
        ),
      );
    }
  }
}

/// The pulled vertex program of [d]: its merged form's when it has one.
String _pulledVertexOf(Pulled p, DrawPlan d) =>
    p.merged[d.pixel]?.vertex ?? d.vertex;

/// The pulled pixel program of [d]: its merged form's when it has one.
String? _pulledPixelOf(Pulled p, DrawPlan d) =>
    d.pixel == null ? null : p.merged[d.pixel]?.pixel ?? d.pixel;
