part of 'frame_runner.dart';

/// A growable byte buffer reused from frame to frame.
class _Bytes {
  Uint8List bytes = Uint8List(4096);
  int length = 0;
  late ByteData _data = ByteData.sublistView(bytes);

  void reset() => length = 0;

  void _room(int n) {
    if (length + n <= bytes.length) return;
    var size = bytes.length * 2;
    while (size < length + n) {
      size *= 2;
    }
    bytes = Uint8List(size)..setRange(0, length, bytes);
    _data = ByteData.sublistView(bytes);
  }

  /// Appends [b] at the end, then zeros up to a 16-byte boundary.
  void add(Uint8List b, [int? count]) {
    final n = count ?? b.length;
    _room(n + 16);
    bytes.setRange(length, length + n, b);
    length += n;
    while (length % 16 != 0) {
      bytes[length++] = 0;
    }
  }

  void setUint32(int at, int v) => _data.setUint32(at, v, Endian.little);

  /// Appends [n] floats of [src] from [from], then zeros up to [total]
  /// floats and a 16-byte boundary ([add] of a list of them, without it).
  void addFloats(Float32List src, int from, int n, int total) {
    _room(total * 4 + 16);
    final d = _data;
    for (var j = 0; j < n; j++) {
      d.setFloat32(length + j * 4, src[from + j], Endian.little);
    }
    for (var j = n; j < total; j++) {
      d.setFloat32(length + j * 4, 0, Endian.little);
    }
    length += total * 4;
    while (length % 16 != 0) {
      bytes[length++] = 0;
    }
  }

  void addUint32Pair(int a, int b) {
    _room(8);
    _data
      ..setUint32(length, a, Endian.little)
      ..setUint32(length + 4, b, Endian.little);
    length += 8;
  }
}

/// A list compared by the identity of its items (a draw's frame blocks:
/// the builder's roles and kept objects), its strings by value.
class _IdentityKey {
  _IdentityKey(this.items)
    : hashCode = Object.hashAll([
        for (final i in items) i is String ? i.hashCode : identityHashCode(i),
      ]);
  final List<Object?> items;
  @override
  final int hashCode;
  @override
  bool operator ==(Object other) {
    if (other is! _IdentityKey || other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      final (a, b) = (items[i], other.items[i]);
      if (a is String ? a != b : !identical(a, b)) return false;
    }
    return true;
  }
}

/// `PRISMARINE_PULLED_STATS=1`: every 120 prepares, their time (p50, p90)
/// and how many draws' pulled forms were made new.
class _PulledStats {
  static final on = envVar('PULLED_STATS') == '1';
  final _us = <int>[];
  int made = 0;

  void add(int us, void Function(String)? warn) {
    if (!on) return;
    _us.add(us);
    if (_us.length < 120) return;
    _us.sort();
    warn?.call(
      's2 pulled stats: prepare p50 ${_us[60] / 1000} ms p90 '
      '${_us[108] / 1000} ms max ${_us.last / 1000} ms; $made forms made',
    );
    _us.clear();
    made = 0;
  }
}

final _pulledStats = _PulledStats();

/// A pulled prepare's adding of draws ([_RunnerPulled._pulledPrepareTimed]):
/// methods over the frame's state, not a closure per prepare.
extension _RunnerPulledAdd on FrameRunner {
  /// [block]'s material row in [f] (its role's bytes this frame), added
  /// when new.
  int _pulledMaterial(_PulledFrame f, Uint8List? block) {
    if (block == null) return 0;
    final bytes = block.isEmpty ? _frameBlocks[block] ?? block : block;
    final had = f.materialAt[bytes];
    if (had != null) return had;
    final at = f.materials.length ~/ 4;
    f.materials.add(bytes);
    return f.materialAt[bytes] = at;
  }

  /// [d]'s [name] block, either stage's; a role's in a row makes the rows
  /// not keepable.
  Uint8List? _pulledBlock(_PulledFrame f, DrawPlan d, String name, bool row) {
    final b = d.pixelResources.blocks[name] ?? d.vertexResources.blocks[name];
    if (b != null && b.isEmpty && row) f.keepable = false;
    return b;
  }

  /// Adds draw [i] of [draws] to [f]'s buckets, or to its rest when it has
  /// no pulled form ([rowCount]: the rows come first; [bounds]: a cascade
  /// pass's rows).
  void _pulledAdd(
    _PulledFrame f,
    List<DrawPlan> draws,
    int i,
    Float32List? bounds,
    int rowCount,
  ) {
    final d = draws[i];
    final c = _pulledOf(d);
    if (c.reason case final r?) {
      f.why[r] = (f.why[r] ?? 0) + 1;
      // A cascade row has no record form (no caster cull of its own):
      // loud, for the cook to take it.
      if (bounds != null && i < rowCount) {
        if (_failedDraws.add('${d.label}: cascade row not pulled: $r')) {
          warn?.call('s2 cascade row not pulled: ${d.label}: $r');
        }
        return;
      }
      f.rest.add(d);
      return;
    }
    final layout = pulled!.layout;
    final objectRow = layout.objectRow, instanceRow = layout.instanceRow;
    final buckets = f.buckets;
    final key = c.key!;
    var bucket = buckets[key];
    if (bucket == null) {
      // Last frame's bucket of the key while it is made of the same, its
      // views kept with it (perf: a bucket and its two views per bucket a
      // frame).
      final had = f.bucketPool[key];
      if (had != null &&
          identical(had.first, d) &&
          identical(had.scene, c.scene) &&
          had.pool == c.batch!.pool &&
          identical(had.arrays, c.arrays) &&
          had.index == buckets.length) {
        bucket = had
          ..clusters = 0
          ..start = 0;
      } else {
        if (f.bucketPool.length > 4096) f.bucketPool.clear();
        bucket = f.bucketPool[key] = _PulledBucket(
          d,
          c.scene!,
          c.batch!.pool,
          c.arrays,
          buckets.length,
        );
      }
      buckets[key] = bucket;
    }
    if (f.camera == null) {
      final cb0 = d.vertexResources.blocks[layout.cameraBlock];
      f
        ..camera = cb0 == null ? null : _frameBlocks[cb0] ?? cb0
        ..cameraSource = cb0;
    }
    final objectBlock = d.vertexResources.blocks[layout.objectBlock];
    final ob = objectBlock == null
        ? _emptyObject
        : objectBlock.isEmpty
        ? _frameBlocks[objectBlock] ?? objectBlock
        : objectBlock;
    var object = f.objectAt[ob];
    if (object == null) {
      f.objectSources.add(objectBlock ?? _emptyObject);
      object = f.objects.length ~/ objectRow.stride;
      f.objects.add(ob, ob.length.clamp(0, objectRow.stride));
      while (f.objects.length % objectRow.stride != 0) {
        f.objects.add(_zero16);
      }
      f.objectAt[ob] = object;
    }
    // A role-bound BufferInstance changes per frame; a kept one is in the
    // cached row already.
    final at = f.instances.length;
    f.instances.add(c.row);
    if (bounds != null && i < rowCount) {
      _cascadeRow(f, at, bounds, i, instanceRow['sphere']);
    }
    final ib = d.vertexResources.blocks[layout.instanceBlock];
    if (ib != null && ib.isEmpty) {
      if (i < rowCount) f.keepable = false;
      final bytes = _frameBlocks[ib] ?? ib;
      // All of BufferInstance but its texcoord transforms (kept at identity
      // in the cached row).
      final uv = instanceRow[layout.uvTransforms.first];
      final past = instanceRow[layout.uvTransforms.last] + 16;
      final end = instanceRow['object'];
      f.instances.bytes
        ..setRange(at, at + bytes.length.clamp(0, uv), bytes)
        ..setRange(at + past, at + bytes.length.clamp(past, end), bytes, past);
    }
    final row = i < rowCount;
    final layerAt = f.materials.length ~/ 4;
    f.materials.add(c.layers);
    f.instances
      ..setUint32(at + instanceRow['object'], object)
      ..setUint32(
        at + instanceRow['materialBase'],
        _pulledMaterial(f, _pulledBlock(f, d, layout.materialBaseBlock, row)),
      )
      ..setUint32(
        at + instanceRow['materialMain'],
        _pulledMaterial(f, _pulledBlock(f, d, layout.materialMainBlock, row)),
      )
      ..setUint32(at + instanceRow['materialTextures'], layerAt)
      ..setUint32(at + instanceRow['bucket'], bucket.index);
    f.instanceCount++;
    bucket.clusters += (c.batch!.indexCount + 191) ~/ 192;
    f.indexCounts.add(c.batch!.indexCount);
  }
}
