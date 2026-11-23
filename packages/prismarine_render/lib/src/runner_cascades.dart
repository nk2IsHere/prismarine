part of 'frame_runner.dart';

// The shadow cascades of the key light in pulled form. The cascade rows of
// the builder are culled per cascade on the GPU by the cascade culling stage
// of the cooked programs, which tests each caster as the builder does.

/// The shader id of the cascade culling stage in the cooked programs.
const _pulledCascadeCull = 'PulledCull/cull_cascades.comp';

/// The number of cascades that a row may draw into, all four tested by the
/// cull.
const _cascadeCount = 4;

/// Writes the [bounds] of row [i] into the instance at byte [at] of the
/// instances of [f], with the sphere of the mesh as the caster test takes
/// it. Writes the box of the mesh into the boxes of [f], 8 floats per
/// instance.
void _cascadeRow(
  _PulledFrame f,
  int at,
  Float32List bounds,
  int i,
  int sphere,
) {
  // Through the kept views, without a view per row.
  final data = f.instances._data;
  for (var k = 0; k < 4; k++) {
    data.setFloat32(at + sphere + k * 4, bounds[i * 10 + k], Endian.little);
  }
  f.boxes.addFloats(bounds, i * 10 + 4, 6, 8);
}

/// The uniform block of the cascade cull, kept and copied by each call.
final _cull = ByteData(64);
final _cullBytes = _cull.buffer.asUint8List();

extension _RunnerCascades on FrameRunner {
  /// Records the cascade culling dispatch into [cb]. [params] holds the
  /// rotation rows of the light, the rectangle of the view and the row count
  /// of the cascades buffer (RowSet.params). [views] holds the objects,
  /// instances, indirect arguments, clusters and bucket bases of the pass.
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
        // Copied into the ring of this frame and not cached by the block,
        // since each call writes it again.
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
