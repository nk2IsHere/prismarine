import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

/// The S2 frame's constant-buffer data: a bump allocator over host-visible
/// blocks, four frames in turn (two frames on the GPU, one recording, one
/// spare). It stands in for flutter_gpu's HostBuffer, which writes past a
/// block's end when an emplacement doesn't fit its remainder (it checks the
/// start, not the end) and grows a frame's block list on every overflow;
/// S2's frames emplace 12 KB light blocks thousands of times.
///
/// An emplacement copies into a CPU copy of its block, and [flush] writes
/// each block's used bytes to the GPU once, before the frame is submitted:
/// a heavy shot's thousands of emplacements each crossed into the engine
/// (a non-leaf call) to write their own few hundred bytes.
class UniformRing {
  static const _blockBytes = 4 << 20;
  static const _frames = 4;

  final _blocks = List.generate(_frames, (_) => <gpu.DeviceBuffer>[]);

  /// Each block's bytes as this frame writes them, and how far.
  final _staging = <Uint8List>[];
  final _used = <int>[];
  int _frame = 0, _block = 0, _offset = 0;

  /// The context's uniform alignment, asked once (a call into the engine).
  late final int _align = gpu.gpuContext.minimumUniformByteAlignment;

  /// Starts the next frame's blocks.
  void reset() {
    _frame = (_frame + 1) % _frames;
    _block = 0;
    _offset = 0;
    _used.fillRange(0, _used.length, 0);
  }

  /// [bytes] placed in this frame's blocks, aligned for a uniform binding;
  /// on the GPU once [flush]ed.
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

  /// Writes this frame's blocks to the GPU: before the frame that binds
  /// them is submitted.
  void flush() {
    final list = _blocks[_frame];
    for (var b = 0; b < list.length && b < _used.length; b++) {
      final n = _used[b];
      if (n == 0) continue;
      if (!list[b].overwrite(ByteData.sublistView(_staging[b], 0, n))) {
        throw StateError('S2 uniform write of $n bytes failed');
      }
    }
  }
}

/// Constant blocks that stay the same from frame to frame, written once
/// into host-visible arenas that later frames bind again: a still shot's
/// thousands of material, instance and batch blocks were copied into each
/// frame's ring anew. A placement appends to the newest arena, so what a
/// frame on the GPU reads is never written again; [flush] writes each
/// arena's new bytes once a frame. Past [_limit] bytes placed the arenas
/// start over at the next run's start ([begin]: [epoch] moves on, and a
/// view of an older epoch is placed again on its next use): blocks no
/// frame binds any more are dropped with them, their arenas let go at
/// once. Left to the collector, the dropped arenas had lived until an
/// old-space mark-sweep (268 MB of them by the end of Ep205's playtest
/// route, docs/areas/perf.md "Memory over an episode").
class BlockStore {
  static const _arenaBytes = 4 << 20;
  static const _limit = 48 << 20;

  /// Bumped whenever the arenas start over: views placed before are not
  /// bound again.
  int epoch = 0;

  final _arenas = <gpu.DeviceBuffer>[];

  /// Each arena's bytes on the CPU, until it is full and written.
  final _staging = <Uint8List?>[];

  /// Each arena's bytes placed and not yet written.
  final _from = <int>[], _to = <int>[];
  int _offset = 0, _placed = 0;
  late final int _align = gpu.gpuContext.minimumUniformByteAlignment;

  /// A run's start, before it binds anything: past [_limit], the arenas
  /// start over. Not in [place]: a run's views placed before a start-over
  /// in [place] were still bound by that run, and their bytes, not yet
  /// [flush]ed, never reached the GPU.
  void begin() {
    if (_placed <= _limit) return;
    // The runs submitted keep what they bound; no later run binds a view
    // of an older epoch.
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

  /// [bytes] placed for good (until the arenas start over); null when it
  /// is larger than an arena.
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

  /// Writes the bytes placed since the last flush: before the frame that
  /// binds them is submitted.
  void flush() {
    for (var k = 0; k < _arenas.length; k++) {
      final from = _from[k], to = _to[k];
      if (to <= from) continue;
      final ok = _arenas[k].overwrite(
        ByteData.sublistView(_staging[k]!, from, to),
        destinationOffsetInBytes: from,
      );
      if (!ok) throw StateError('S2 block store write of ${to - from} bytes');
      _from[k] = _to[k] = 0;
      // A full arena takes no more: its CPU copy goes.
      if (k < _arenas.length - 1) _staging[k] = null;
    }
  }
}
