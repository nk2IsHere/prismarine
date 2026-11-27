part of 'frame_runner.dart';

/// One pipeline bucket of a pulled pass. It holds the draws that share
/// programs, pool, state, arrays and samplers, drawn as one instanced draw
/// of their clusters.
class _PulledBucket {
  // alloc-cold: a bucket that the last frame did not have.
  _PulledBucket(this.first, this.scene, this.pool, this.arrays, this.index);
  final DrawPlan first;
  final _CookedSceneGpu scene;
  final int pool;

  /// The array of each material texture input, by input name.
  final Map<String, gpu.Texture> arrays;

  /// The place of the bucket and of its indirect draw in the buckets of the
  /// frame.
  final int index;

  /// The clusters of this frame and the first of them. The prepare of
  /// [_RunnerPulled] sets them and its record reads them right after.
  int clusters = 0, start = 0;

  /// The recent views of its record, a few of each kind, taken again by
  /// [view] while they hold. The buffers of the frames take turns.
  final clusterViews = List<gpu.BufferView?>.filled(4, null);
  final argViews = List<gpu.BufferView?>.filled(4, null);
  int _viewTurn = 0;

  /// Returns a view of [buffer] from [offset] for [length]. A matching view
  /// of [kept] is returned again.
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
    // alloc: a buffer, offset or length that the last views did not have
    return kept[_viewTurn++ & 3] = gpu.BufferView(
      buffer,
      offsetInBytes: offset,
      lengthInBytes: length,
    );
  }
}

/// The frame of a pulled pass, made before the pass begins ([_RunnerPulled]).
class _PulledPrepared {
  _PulledPrepared(
    this.rest,
    this.restAfter,
    this.ranges,
    this.instances,
    this.objects,
    this.materials,
    this.args,
    this.clusters,
  );

  /// The draws left to their own records.
  final List<DrawPlan> rest;

  /// With [PulledLayout.keepOrder], the buckets drawn before each draw of
  /// [rest]; null otherwise, when [rest] follows every bucket.
  final List<int>? restAfter;

  /// The buckets, each with its first cluster in [_PulledBucket.start].
  final List<_PulledBucket> ranges;
  final gpu.BufferView instances, objects, materials, args;
  final gpu.DeviceBuffer clusters;
}

/// The bits of InstanceRow.flags that carry the output stride in words and
/// the normal count of a skinned instance, as the cooked programs read them.
const _skinStrideShift = 8, _skinNormalsShift = 16;

/// The shader id of the culling stage in the cooked tree.
const _pulledCull = 'PulledCull/cull.comp';

/// The pulled form of a draw, made once per draw object. It holds the
/// bucket key, the cooked batch, the arrays, the texture layers and the
/// instance row up to its per-frame fields. A draw that cannot be pulled
/// keeps the reason.
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

  /// The array layers of the material inputs, a uint each, padded to 16
  /// bytes.
  final Uint8List layers;

  /// The instance row with the bytes of the instance block with the texcoord
  /// transforms at identity and the pool range of the batch. The object and
  /// material offsets are filled per frame.
  final Uint8List row;
}

final _pulledForms = Expando<_PulledDraw>('pulled draws');
