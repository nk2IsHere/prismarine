part of 'frame_runner.dart';

/// The key light's cascades in pulled form (the own-renderer design, R0d):
/// the builder's cascade rows, culled per cascade on the GPU by the cook's
/// cascade culling stage (pulled_program.dart pulledCascadeCullShader),
/// which takes the exe's caster test and the builder's reach.

/// The culling stage's shader id in the cooked tree.
const _pulledCascadeCull = 'PulledCull/cull_cascades.comp';

/// The cascades a row may draw into: CS_CullShadowCasters tests four.
const _cascadeCount = 4;

/// Row [i]'s [bounds] into the instance at byte [at] of [f]'s instances
/// (its sphere the mesh's, as the exe's caster test takes it) and its mesh
/// box into [f]'s boxes, 8 floats an instance.
void _cascadeRow(
  _PulledFrame f,
  int at,
  Float32List bounds,
  int i,
  int sphere,
) {
  // Through the kept views (perf: a view per row, and a box list with its
  // buffer and view).
  final data = f.instances._data;
  for (var k = 0; k < 4; k++) {
    data.setFloat32(at + sphere + k * 4, bounds[i * 10 + k], Endian.little);
  }
  f.boxes.addFloats(bounds, i * 10 + 4, 6, 8);
}

/// The cascade cull's uniform block, kept: emplaced (copied) each call.
final _cull = ByteData(64);
final _cullBytes = _cull.buffer.asUint8List();

extension _RunnerCascades on FrameRunner {
  /// The cascade culling dispatch into [cb]: [params] are the light's
  /// rotation rows, the view's rectangle and the cascades buffer's row
  /// count (RowSet.params); [views] the pass's objects, instances,
  /// indirect arguments, clusters and bucket bases.
  void _cascadeCull(
    gpu.CommandBuffer cb,
    UniformRing host,
    _PulledFrame f,
    _PulledFrameBuffers slot,
    Float32List params,
    int instanceCount,
    (
      gpu.BufferView,
      gpu.BufferView,
      gpu.BufferView,
      gpu.BufferView,
      gpu.BufferView,
    )
    views,
  ) {
    final (objects, instances, args, clusters, bases) = views;
    final cull = _cull;
    for (var k = 0; k < 12; k++) {
      cull.setFloat32(k * 4, params[k], Endian.little);
    }
    cull
      ..setUint32(48, instanceCount, Endian.little)
      ..setUint32(52, params[12].toInt(), Endian.little);
    final boxes = slot.put(
      _PulledFrameBuffers.boxesKind,
      f.boxes.bytes,
      f.boxes.length,
    );
    final shader = pulled!.shaders.shader(_pulledCascadeCull);
    final pipeline = _computePipelines[_pulledCascadeCull] ??= gpu.gpuContext
        .createComputePipeline(shader);
    cb.createComputePass()
      ..bindPipeline(pipeline)
      ..bindUniform(
        _uniformSlot(shader, 'BufferPulledCascadeCull'),
        // Copied into this frame's ring, never cached by the block (it is
        // written again each call).
        host.emplace(_cullBytes),
      )
      ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledObjects'), objects)
      ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledInstances'), instances)
      ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledArgs'), args)
      ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledClusters'), clusters)
      ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledBuckets'), bases)
      ..bindStorageBuffer(_bufferSlot(shader, 'RawPulledBoxes'), boxes)
      ..bindStorageBuffer(
        _bufferSlot(shader, 'RawPulledCascades'),
        _bufferView(pulled!.layout.cascadesRef),
      )
      ..dispatch((instanceCount + 63) ~/ 64);
  }
}
