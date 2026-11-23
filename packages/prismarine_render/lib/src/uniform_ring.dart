import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

/// The constant-buffer data of a frame in a bump allocator over host-visible
/// blocks, four frames in turn. Two frames are on the GPU, one records and
/// one is spare. It stands in for the HostBuffer of flutter_gpu, which
/// writes past the end of a block when an emplacement does not fit its
/// remainder and grows the block list of a frame on every overflow. A frame
/// may emplace 12 KB blocks thousands of times.
///
/// An emplacement copies into a CPU copy of its block. [flush] writes the
/// used bytes of each block to the GPU once, before the frame is submitted.
class UniformRing {
  static const _blockBytes = 4 << 20;
  static const _frames = 4;

  final _blocks = List.generate(_frames, (_) => <gpu.DeviceBuffer>[]);

  /// The bytes of each block as this frame writes them, with their extent.
  final _staging = <Uint8List>[];
  final _used = <int>[];
  int _frame = 0, _block = 0, _offset = 0;

  /// The uniform alignment of the context, asked once from the engine.
  late final int _align = gpu.gpuContext.minimumUniformByteAlignment;

  /// Starts the blocks of the next frame.
  void reset() {
    _frame = (_frame + 1) % _frames;
    _block = 0;
    _offset = 0;
    _used.fillRange(0, _used.length, 0);
  }

  /// Places [bytes] in the blocks of this frame, aligned for a uniform binding.
  /// Returns their view. They are on the GPU after [flush].
  gpu.BufferView emplace(Uint8List bytes) {
    final n = bytes.length;
    final align = _align;
    var at = (_offset + align - 1) ~/ align * align;
    final list = _blocks[_frame];
    if (n > _blockBytes) {
      gpu.GpuMemory.tag = 'buffer.ringLarge';
      final own = gpu.gpuContext.createDeviceBuffer(
        gpu.StorageMode.hostVisible,
        n,
      )..overwrite(ByteData.sublistView(bytes));
      gpu.GpuMemory.tag = null;
      return gpu.BufferView(own, offsetInBytes: 0, lengthInBytes: n);
    }
    if (list.isEmpty || at + n > _blockBytes) {
      if (list.isNotEmpty) _block++;
      at = 0;
    }
    while (list.length <= _block) {
      gpu.GpuMemory.tag = 'buffer.ring';
      list.add(
        gpu.gpuContext.createDeviceBuffer(
          gpu.StorageMode.hostVisible,
          _blockBytes,
        ),
      );
      gpu.GpuMemory.tag = null;
    }
    while (_staging.length <= _block) {
      _staging.add(Uint8List(_blockBytes));
      _used.add(0);
    }
    _staging[_block].setRange(at, at + n, bytes);
    _offset = at + n;
    if (_offset > _used[_block]) _used[_block] = _offset;
    return gpu.BufferView(list[_block], offsetInBytes: at, lengthInBytes: n);
  }

  /// Writes the blocks of this frame to the GPU. Call it before the frame
  /// that binds them is submitted.
  void flush() {
    final list = _blocks[_frame];
    for (var b = 0; b < list.length && b < _used.length; b++) {
      final n = _used[b];
      if (n == 0) continue;
      if (!list[b].overwrite(ByteData.sublistView(_staging[b], 0, n))) {
        throw StateError('uniform ring: writing $n bytes failed');
      }
    }
  }
}

/// Constant blocks that stay the same from frame to frame, written once into
/// host-visible arenas that later frames bind again. A placement appends to the
/// newest arena. The bytes that a frame on the GPU reads are not written again.
/// [flush] writes the new bytes of each arena once a frame. Past [_limit]
/// placed bytes the arenas start over at the start of the next run in [begin].
/// [epoch] then moves on. A view of an older epoch is placed again on its next
/// use. Blocks that no frame binds any more are dropped with the arenas, which
/// are let go at once and not left to an old-space collection.
class BlockStore {
  static const _arenaBytes = 4 << 20;
  static const _limit = 48 << 20;

  /// Raised whenever the arenas start over. Views placed before are not
  /// bound again.
  int epoch = 0;

  final _arenas = <gpu.DeviceBuffer>[];

  /// The bytes of each arena on the CPU, until it is full and written.
  final _staging = <Uint8List?>[];

  /// The range of the bytes of each arena placed and not yet written.
  final _from = <int>[], _to = <int>[];
  int _offset = 0, _placed = 0;
  late final int _align = gpu.gpuContext.minimumUniformByteAlignment;

  /// Starts a run before it binds anything. Past [_limit] the arenas start
  /// over here and not in [place]. A start-over in [place] would drop views
  /// that the run placed before and still binds, whose bytes have not
  /// reached the GPU through [flush].
  void begin() {
    if (_placed <= _limit) return;
    // The submitted runs keep what they bound. No later run binds a view of
    // an older epoch.
    for (final a in _arenas) {
      a.mcsmRelease();
    }
    _arenas.clear();
    _staging.clear();
    _from.clear();
    _to.clear();
    _placed = 0;
    epoch++;
  }

  /// Places [bytes] for good, until the arenas start over. Returns their view.
  /// Returns null when [bytes] is larger than an arena.
  gpu.BufferView? place(Uint8List bytes) {
    final n = bytes.length;
    if (n > _arenaBytes) return null;
    var at = (_offset + _align - 1) ~/ _align * _align;
    if (_arenas.isEmpty || at + n > _arenaBytes) {
      gpu.GpuMemory.tag = 'buffer.store';
      _arenas.add(
        gpu.gpuContext.createDeviceBuffer(
          gpu.StorageMode.hostVisible,
          _arenaBytes,
        ),
      );
      gpu.GpuMemory.tag = null;
      _staging.add(Uint8List(_arenaBytes));
      _from.add(0);
      _to.add(0);
      at = 0;
    }
    final k = _arenas.length - 1;
    _staging[k]!.setRange(at, at + n, bytes);
    if (_to[k] <= _from[k]) _from[k] = at;
    _to[k] = at + n;
    _offset = at + n;
    _placed += n;
    return gpu.BufferView(_arenas[k], offsetInBytes: at, lengthInBytes: n);
  }

  /// Writes the bytes placed since the last flush. Call it before the frame
  /// that binds them is submitted.
  void flush() {
    for (var k = 0; k < _arenas.length; k++) {
      final from = _from[k], to = _to[k];
      if (to <= from) continue;
      final ok = _arenas[k].overwrite(
        ByteData.sublistView(_staging[k]!, from, to),
        destinationOffsetInBytes: from,
      );
      if (!ok) {
        throw StateError('block store: writing ${to - from} bytes failed');
      }
      _from[k] = _to[k] = 0;
      // A full arena takes no more bytes and its CPU copy goes.
      if (k < _arenas.length - 1) _staging[k] = null;
    }
  }
}
