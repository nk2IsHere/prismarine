part of 'frame_runner.dart';

/// The part of the rows of a pulled pass as one frame made it. The runner
/// keeps its tables while the rows hold. It has the instance, box and
/// material bytes, the block of each object row as bound, the buckets with
/// their clusters, the rows left to records with the reason and the camera
/// block. It is taken again into the same storage when the rows of the
/// reader change.
final class _KeptRows {
  // alloc-cold: once per pulled pass, with its pulled frame.
  _KeptRows();

  List<DrawPlan> plans = const [];
  final _instances = _Bytes(), _boxes = _Bytes(), _materials = _Bytes();
  final _materialAt = KeptMap<Uint8List, int>.identity();
  final _objectSources = KeptList<Uint8List>();
  final _bucketKeys = KeptList<Object>();
  final _buckets = KeptList<_PulledBucket>();
  final _clusters = KeptList<int>();

  /// The buckets that each frame restores into, one per kept bucket, with
  /// their counts reset.
  final _live = KeptList<_PulledBucket>();
  final _rest = KeptList<DrawPlan>();
  final _why = KeptMap<String, int>();
  final _indexCounts = KeptList<int>();
  int instanceCount = 0;
  Uint8List? camera;

  // alloc-cold: the rows of a pulled pass changed.
  /// Takes the state of [f] after the rows of [plans] were added.
  _KeptRows take(
    _PulledFrame f,
    List<DrawPlan> plans,
    Map<Object, _PulledBucket> buckets,
    List<DrawPlan> rest,
    Map<String, int> why,
    int instanceCount,
    Uint8List? camera,
  ) {
    this.plans = plans;
    _copy(_instances, f.instances);
    _copy(_boxes, f.boxes);
    _copy(_materials, f.materials);
    _materialAt
      ..clear()
      ..addAll(f.materialAt);
    _objectSources
      ..clear()
      ..addAll(f.objectSources);
    _bucketKeys.clear();
    _buckets.clear();
    _clusters.clear();
    buckets.forEach((key, b) {
      _bucketKeys.add(key);
      _buckets.add(b);
      _clusters.add(b.clusters);
    });
    _live.clear();
    for (var k = 0; k < _buckets.length; k++) {
      final b = _buckets[k];
      _live.add(_PulledBucket(b.first, b.scene, b.pool, b.arrays, b.index));
    }
    _rest
      ..clear()
      ..addAll(rest);
    _why
      ..clear()
      ..addAll(why);
    _indexCounts
      ..clear()
      ..addAll(f.indexCounts);
    this.instanceCount = instanceCount;
    this.camera = camera;
    return this;
  }

  static void _copy(_Bytes to, _Bytes from) {
    to.reset();
    to._room(from.length);
    to.bytes.setRange(0, from.length, from.bytes);
    to.length = from.length;
  }

  /// Puts the kept part into [f] and the lists of the frame. The bytes of
  /// the objects are read again from the roles of this frame in
  /// [frameBlocks] into rows of [objectRow].
  void restore(
    RowLayout objectRow,
    _PulledFrame f,
    Map<Object, _PulledBucket> into,
    List<DrawPlan> restInto,
    Map<String, int> whyInto,
    List<int> indexCountsInto,
    Map<Uint8List, Uint8List> frameBlocks,
  ) {
    f.instances.add(_instances.bytes, _instances.length);
    if (_boxes.length > 0) f.boxes.add(_boxes.bytes, _boxes.length);
    f.materials.add(_materials.bytes, _materials.length);
    f.materialAt.addAll(_materialAt);
    for (var k = 0; k < _objectSources.length; k++) {
      final source = _objectSources[k];
      final ob = source.isEmpty ? frameBlocks[source] ?? source : source;
      final i = f.objects.length ~/ objectRow.stride;
      f.objectAt[ob] ??= i;
      f.objectSources.add(source);
      f.objects.add(ob, ob.length.clamp(0, objectRow.stride));
      while (f.objects.length % objectRow.stride != 0) {
        f.objects.add(_zero16);
      }
    }
    // The live buckets and not the kept ones, since their cluster counts
    // are scaled per pass.
    for (var k = 0; k < _live.length; k++) {
      into[_bucketKeys[k]] = _live[k]
        ..clusters = _clusters[k]
        ..start = 0;
    }
    restInto.addAll(_rest);
    whyInto.addAll(_why);
    indexCountsInto.addAll(_indexCounts);
  }
}
