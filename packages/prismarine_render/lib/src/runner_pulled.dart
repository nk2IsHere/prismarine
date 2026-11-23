part of 'frame_runner.dart';

/// A pulled pass's per-frame scratch and buffers, kept by the runner per
/// pass: a frame's passes are prepared before the GPU runs the first, so
/// none shares another's.
class _PulledFrame {
  final instances = _Bytes(), objects = _Bytes(), materials = _Bytes();
  final clusters = _Bytes(), bases = _Bytes(), args = _Bytes();

  /// A cascade pass's rows' mesh boxes (8 floats an instance).
  final boxes = _Bytes();

  /// Each object row's block as the draws bind it (a role's is read again
  /// each frame), and the rows' part as last made ([_KeptRows]).
  final objectSources = KeptList<Uint8List>();
  _KeptRows? kept;

  /// [kept]'s storage, refilled when the rows change (also while [kept] is
  /// null).
  final keptStore = _KeptRows();
  final objectAt = KeptMap<Uint8List, int>.identity(),
      materialAt = KeptMap<Uint8List, int>.identity();
  final indexCounts = KeptList<int>();

  /// A prepare's state while its draws are added (_pulledAdd), kept from
  /// frame to frame and cleared, storage kept (perf: a closure and its
  /// context per prepare, and collections that grew from empty each
  /// frame).
  final rest = KeptList<DrawPlan>();
  final why = KeptMap<String, int>();
  final buckets = KeptMap<Object, _PulledBucket>();

  /// The last bucket made per key, taken again while it holds.
  final bucketPool = KeptMap<Object, _PulledBucket>();
  bool keepable = true;
  int instanceCount = 0;
  Uint8List? camera, cameraSource;
  final slots = [
    _PulledFrameBuffers(),
    _PulledFrameBuffers(),
    _PulledFrameBuffers(),
  ];

  /// The buckets in cluster order, and their base words (perf: a list and
  /// a record per bucket, and the words, a frame).
  final ranges = KeptList<_PulledBucket>();
  var words = Uint32List(0);
  var wordBytes = Uint8List(0);
}

/// A pulled bucket's views for its stages ([_RunnerPulled._pulledStage]):
/// clusters, instances, objects, materials.
final _stageViews = List<gpu.BufferView?>.filled(4, null);

final _emptyObject = Uint8List(16);

/// Zeros padding an object row (added by copy, never written).
final _zero16 = Uint8List(16);

/// One pipeline bucket of a pulled pass: the draws that share programs,
/// pool, state, arrays and samplers, drawn as one instanced draw of their
/// clusters.
class _PulledBucket {
  _PulledBucket(this.first, this.scene, this.pool, this.arrays, this.index);
  final DrawPlan first;
  final _CookedSceneGpu scene;
  final int pool;

  /// Each material texture input's array (by input name).
  final Map<String, gpu.Texture> arrays;

  /// Its place in the frame's buckets: its indirect draw's.
  final int index;

  /// This frame's clusters, and the first of them ([_RunnerPulled]'s
  /// prepare sets it; its record reads it right after).
  int clusters = 0, start = 0;

  /// Its record's views as made of late, a few of each (the frames' buffers
  /// come in turn, so one view a kind was new every frame), taken again
  /// while they hold ([view]).
  final clusterViews = List<gpu.BufferView?>.filled(4, null);
  final argViews = List<gpu.BufferView?>.filled(4, null);
  int _viewTurn = 0;

  /// A view of [buffer] from [offset] for [length]: one of [kept] when it
  /// is that (perf: two views per bucket a frame).
  gpu.BufferView view(
    List<gpu.BufferView?> kept,
    gpu.DeviceBuffer buffer,
    int offset,
    int length,
  ) {
    for (var i = 0; i < kept.length; i++) {
      final had = kept[i];
      if (had != null &&
          identical(had.buffer, buffer) &&
          had.offsetInBytes == offset &&
          had.lengthInBytes == length) {
        return had;
      }
    }
    return kept[_viewTurn++ & 3] = gpu.BufferView(
      buffer,
      offsetInBytes: offset,
      lengthInBytes: length,
    );
  }
}

/// A pulled pass's frame, made before the pass begins ([_RunnerPulled]).
class _PulledPrepared {
  _PulledPrepared(
    this.rest,
    this.ranges,
    this.instances,
    this.objects,
    this.materials,
    this.args,
    this.clusters,
  );

  /// The draws left to their own records.
  final List<DrawPlan> rest;

  /// The buckets, each with its first cluster ([_PulledBucket.start]).
  final List<_PulledBucket> ranges;
  final gpu.BufferView instances, objects, materials, args;
  final gpu.DeviceBuffer clusters;
}

/// Where InstanceRow.flags carries a skinned instance's output stride (in
/// words) and its normal count (pulled_program.dart skinStrideShift).
const _skinStrideShift = 8, _skinNormalsShift = 16;

/// The culling stage's shader id in the cooked tree.
const _pulledCull = 'PulledCull/cull.comp';

/// What a draw is in pulled form, made once per draw object (the builder
/// keeps a still batch's draw from frame to frame): its bucket key, cooked
/// batch, arrays, texture layers and instance row up to its per-frame
/// fields. A draw that can't be pulled keeps why.
class _PulledDraw {
  _PulledDraw.refused(this.reason)
    : key = null,
      scene = null,
      batch = null,
      arrays = const {},
      layers = Uint8List(0),
      row = Uint8List(0);
  _PulledDraw(
    this.key,
    this.scene,
    this.batch,
    this.arrays,
    this.layers,
    this.row,
  ) : reason = null;
  final String? reason;
  final Object? key;
  final _CookedSceneGpu? scene;
  final CookedBatch? batch;
  final Map<String, gpu.Texture> arrays;

  /// The material inputs' array layers, a uint each, padded to 16 bytes.
  final Uint8List layers;

  /// The instance row: BufferInstance's bytes (texcoord transforms at
  /// identity) and the batch's pool range; object and material offsets are
  /// written per frame.
  final Uint8List row;
}

final _pulledForms = Expando<_PulledDraw>('pulled draws');

/// A frame's pulled buffers, kept and overwritten: one set per frame in
/// flight, as the runner keeps three frames' plan buffers.
class _PulledFrameBuffers {
  gpu.DeviceBuffer? instances, objects, materials, clusters, args, bases;
  gpu.DeviceBuffer? boxes;

  /// A view of the whole of [clusters].
  gpu.BufferView? clusterView;

  /// The buffers [put] writes, by kind.
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

  /// [bytes] (the first [length]) in the buffer of [kind], grown when too
  /// small (a kind, not a getter and setter pair: two closures a buffer a
  /// prepare; perf).
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

/// What of a draw's state its bucket shares: the fields, not the object
/// (the builder makes a state per draw).
String _stateKey(DrawState s) =>
    '${s.cull}|${s.frontCounterClockwise}|${s.depthTest}|${s.depthWrite}|'
    '${s.depthFunc}|${s.topology}|${s.depthBias}|${s.slopeScaledDepthBias}|'
    '${s.depthBiasClamp}|'
    '${s.stencil == null ? '' : '${s.stencil!.func},${s.stencil!.passOp},${s.stencil!.readMask},${s.stencil!.writeMask}'}|'
    '${[for (final b in s.blends) '${b.enabled}${b.color}${b.alpha}'].join(';')}';

/// A texture reference as a bucket compares it: by what it names (a plan
/// read from its files makes a reference object per draw), its bytes by
/// identity (blocks and texels are kept objects).
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

/// Storage names as the pulled stage matches them (`Raw<Name>` lower-cased
/// without `raw`) and pool streams' names as `pool<name>`: made once, not
/// for every binding of every frame.
final _storageKeys = <String, String>{};
final _poolKeys = <String, String>{};

/// Each stage's storage names in order ([_RunnerPulled._pulledStage]).
final _storageNames = Expando<List<String>>('pulled storage names');

/// The pool's stream whose name, as `pool<name>` lower-cased without
/// underscores, is [n]: a loop, where a closure per storage binding gave
/// the stage a context each call.
gpu.BufferView _poolStream(_PoolGpu pool, String n, String id, String name) =>
    pool.byStorage[n] ?? (pool.byStorage[n] = _findStream(pool, n, id, name));

gpu.BufferView _findStream(_PoolGpu pool, String n, String id, String name) {
  for (final key in pool.streams.keys) {
    final k = _poolKeys[key] ??= 'pool${key.replaceAll('_', '').toLowerCase()}';
    if (k == n) return pool.streams[key]!;
  }
  throw StateError('$id: no pool stream $name');
}

extension _RunnerPulled on FrameRunner {
  /// [d] in pulled form, made on its first frame and kept with it.
  _PulledDraw _pulledOf(DrawPlan d) {
    final had = _pulledForms[d];
    if (had != null && !(had.scene?.dead ?? false)) return had;
    return _pulledForms[d] = _makePulled(d);
  }

  // The miss path in a method of its own: an inline closure capturing [d]
  // gave every call a context, hits included (perf).
  _PulledDraw _makePulled(DrawPlan d) {
    _pulledStats.made++;
    final p = pulled!;
    final layout = p.layout, instanceRow = layout.instanceRow;
    final g = d.geometry;
    final reason = switch (g) {
      // A skinned batch reads the frame's skinning output: one buffer for
      // all its streams (the batched or the mesh's own output).
      DrawMeshGeometry(streams: final st)
          when st.isNotEmpty &&
              st.values.map((e) => e.$1.buffer).toSet().length != 1 =>
        'skinned',
      DrawMeshGeometry(indirect: final i) when i != null => 'indirect',
      // A blended draw's place in the pass is the picture: it keeps its
      // record, after the pulled buckets (opaque draws test depth equal).
      DrawMeshGeometry() when d.state.blends.any((b) => b.enabled) => 'blended',
      DrawMeshGeometry() when !p.shaders.hasShader(d.vertex) =>
        'no pulled vertex',
      DrawMeshGeometry()
          when d.pixel != null && !p.shaders.hasShader(d.pixel!) =>
        'no pulled pixel',
      DrawMeshGeometry()
          when _pulledOnly != null &&
              !_pulledOnly!.any((t) => d.label.contains(t)) =>
        'not chosen',
      DrawMeshGeometry() => null,
      _ => 'not a mesh',
    };
    if (reason != null) return _PulledDraw.refused(reason);
    g as DrawMeshGeometry;
    // A shadow batch's indices are the mesh's shadow index buffer's.
    final found = p.batch(
      g.mesh,
      g.firstIndex,
      g.indexCount,
      shadow: g.ibuffer == 1,
      scene: _warm.pulledScene,
    );
    if (found == null) return _PulledDraw.refused('not cooked');
    final (scene, batch) = found;
    // The material inputs' arrays, and each texture's layer.
    final arrays = <String, gpu.Texture>{};
    final layers = <int>[];
    var arrayKey = '';
    for (final MapEntry(:key, :value) in d.pixelResources.textures.entries) {
      if (!key.startsWith(layout.materialTexturePrefix)) continue;
      if (value is! FileTexture) continue;
      final at = scene.scene.textureAt(value.stem);
      if (at == null) continue;
      final a = scene.scene.arrays[at.$1];
      arrays[key] = scene.textures.texture(a.file, srgb: value.srgb);
      final n = int.parse(key.substring(layout.materialTexturePrefix.length));
      while (layers.length <= n) {
        layers.add(0);
      }
      layers[n] = at.$2;
      arrayKey += '$key=${a.file}:${value.srgb};';
    }
    // Every material input the pulled pixel stage declares needs a cooked
    // array (a swapped or another scene's texture may have none).
    final pixel = d.pixel == null ? null : p.shaders.shaderRecord(d.pixel!);
    for (final t in pixel?.textures ?? const <TextureSlot>[]) {
      if (t.name.startsWith(layout.materialTexturePrefix) &&
          !arrays.containsKey(t.name)) {
        return _PulledDraw.refused('texture not cooked');
      }
    }
    final layerBytes = Uint8List((layers.length * 4 + 15) & ~15);
    for (var i = 0; i < layers.length; i++) {
      layerBytes.buffer.asByteData().setUint32(i * 4, layers[i], Endian.little);
    }
    // The instance row: BufferInstance's bytes, the texcoord transforms at
    // identity (the cooked UVs carry them), then the batch's range.
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
    // A skinned batch's output: its first word, its stride in words and
    // its normal count (12 bytes and 4 a normal; pulled_program.dart), and
    // no sphere test (its bind-pose sphere doesn't hold the pose; the
    // builder culled it).
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
      d.vertex,
      d.pixel,
      skin?.$1.buffer,
      scene.dir,
      batch.pool,
      d.stencilRef,
      _stateKey(d.state),
      d.viewport.join(','),
      arrayKey,
      // The bucket binds its first draw's samplers and frame resources.
      [
        for (final res in [d.vertexResources, d.pixelResources])
          for (final MapEntry(:key, :value) in res.samplers.entries)
            '$key:${_samplerKey(value)}',
      ].join(';'),
      _IdentityKey([
        for (final res in [d.vertexResources, d.pixelResources]) ...[
          for (final MapEntry(:key, :value) in res.blocks.entries)
            if (!layout.rowBlocks.contains(key)) ...[key, value],
          for (final MapEntry(:key, :value) in res.textures.entries)
            if (!key.startsWith(layout.materialTexturePrefix)) ...[
              key,
              _textureKey(value),
            ],
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

  /// Makes [draws]' (one render pass's) pulled frame before the pass
  /// begins: their rows, each bucket's cluster range, and the culling
  /// dispatch into [cb] that fills the ranges and the buckets' indirect
  /// draws. A draw is pulled when its mesh batch is cooked, its programs
  /// have pulled forms, and it reads no skinning output or indirect
  /// arguments; the rest stay for the plan's own records. Null when none is
  /// pulled.
  _PulledPrepared? _pulledPrepare(
    gpu.CommandBuffer cb,
    String pass,
    List<DrawPlan> draws,
    UniformRing host,
    RowSet? rows,
  ) {
    final clock = Stopwatch()..start();
    try {
      return _pulledPrepareTimed(cb, pass, draws, host, rows);
    } finally {
      _pulledStats.add(clock.elapsedMicroseconds, warn);
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
    // (runner_cascades.dart); its rows come first in [draws].
    final bounds = rows?.bounds;
    final rowCount = rows?.plans.length ?? 0;

    final f = _pulledFrames[pass] ??= _PulledFrame();
    f.boxes.reset();
    final rest = f.rest..clear();
    final why = f.why..clear();
    final buckets = f.buckets..clear();
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

    // The rows' part as last frame made it while the reader's rows are the
    // same draws (the own-renderer design, R0c): only the objects' bytes
    // are read again (a moving agent's BufferObject is its role's).
    final kept = f.kept;
    if (rows != null && kept != null && identical(kept.plans, rows.plans)) {
      kept.restore(
        pulled!.layout.objectRow,
        f,
        buckets,
        rest,
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
      warn?.call(
        's2 pulled: $instanceCount draws in ${buckets.length} buckets, '
        '${rest.length} left to their records $why',
      );
    }
    // Each bucket's cluster range, on a 256-byte boundary (Metal's offset
    // alignment), as many clusters as its instances have; the bases and the
    // indirect draws' arguments with their counts at zero.
    // Kept per pass (perf: a list and a record per bucket a frame).
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
    // The bases, a uint each: the pairs above hold one in their first.
    // The words through the bases' own data view (perf: two views a
    // bucket).
    if (f.words.length < buckets.length) {
      f.words = Uint32List(buckets.length * 2);
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
    // A bucket's view is rounded up to 256 bytes past its last cluster.
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
    // One view per cluster buffer (perf: one per prepare).
    var clusterView = slot.clusterView;
    if (clusterView == null || !identical(clusterView.buffer, clusters)) {
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
      // The cull: the camera's planes (the builder's, from the camera
      // block's view-projection) and the instance count.
      final planes = pulled!.layout.frustumPlanes(
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
      ranges,
      instanceView,
      objectView,
      materialView,
      argsView,
      clusters,
    );
  }

  /// Records [p]'s buckets into [pass]: one indirect draw each, of the
  /// clusters the culling kept.
  void _pulledRecord(gpu.RenderPass pass, _PulledPrepared p, UniformRing host) {
    final ranges = p.ranges;
    for (var i = 0; i < ranges.length; i++) {
      final b = ranges[i], start = b.start;
      if (b.clusters == 0) continue;
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
    // Kept with the bucket's first draw (a kept draw is the same object
    // from frame to frame): its pulled setup was made per bucket a frame.
    final cache = _cacheOf(d);
    if (cache.pulledFixed == null && _Warm.on) {
      _warm.learn(d.vertex, pulled: true);
    }
    final setup = cache.pulled ??= _pulledSetup(p, d);
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
    // The views through fields (perf: a record per stage).
    _stageViews
      ..[0] = clusters
      ..[1] = instances
      ..[2] = objects
      ..[3] = materials;
    _pulledStage(pass, host, b, pool, d, vs, d.vertex, d.vertexResources);
    if (d.pixel != null) {
      _pulledStage(pass, host, b, pool, d, fs, d.pixel!, d.pixelResources);
    }
    pass.drawIndirect(args);
  }

  /// A pulled bucket's draw's shaders and pipeline.
  _DrawSetup _pulledSetup(Pulled p, DrawPlan d) {
    final vs = p.shaders.shader(d.vertex);
    final fs = d.pixel == null
        ? assets.shader(_depthOnly(d))
        : p.shaders.shader(d.pixel!);
    final pipeline = _pipelines[('pulled', d.vertex, d.pixel)] ??= gpu
        .gpuContext
        .createRenderPipeline(
          vs,
          fs,
          // A pulled vertex has no inputs: its place in its cluster is
          // gl_VertexIndex (pulled_program.dart).
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

  /// Binds stage [id]'s ([shader]'s) inputs of bucket [b]'s draw [d]: a
  /// method, where a closure capturing the bucket's locals was made per
  /// bucket a frame.
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
    // By index, the storage names listed once per stage (perf: an iterator
    // per walk, three walks per bucket a frame).
    final blocks = info.blocks;
    for (var k = 0; k < blocks.length; k++) {
      final block = blocks[k];
      pass.bindUniform(
        _uniformSlot(shader, block.name),
        _uniform(host, res.blocks[block.name], block.rows * 16),
      );
    }
    final names = _storageNames[info] ??= info.storage.keys.toList(
      growable: false,
    );
    for (var k = 0; k < names.length; k++) {
      final name = names[k];
      // `Raw<Name>` (pulled_program.dart), as the shader index lists them.
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
      if (t.name.startsWith(p.layout.materialTexturePrefix)) {
        final tex = b.arrays[t.name];
        if (tex == null) {
          throw StateError('$id: no array for ${t.name}');
        }
        pass.bindSeparateTexture(_textureSlot(shader, t.name), tex);
        continue;
      }
      // A frame texture or texel buffer, as the draw's own record binds it.
      final ref = res.textures[t.name];
      if (t.type.contains('Buffer')) {
        // Two locals, not a record (perf: one per texel bind).
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
    for (var k = 0; k < samplers.length; k++) {
      final (slot, compare) = samplers[k];
      pass.bindSeparateSampler(
        _samplerSlot(shader, slot),
        _sampler(
          res.samplers[slot] ??
              (compare ? defaultCompareSampler : defaultSampler),
        ),
      );
    }
  }
}
