// The checks of engine release prismarine1 for the old space of the VM
// (flutter_gpu G16 over PrismarineOldSpace and PrismarineHeap of the engine).
//
// - The heap figures are in range. The old space and the new space use at
//   most their capacity and an unknown figure is -1.
// - Request 1 starts an old-space mark.
// - Request 2 runs a compaction. After 64 MB of small objects in the old
//   space with every other one dropped, the capacity of the old space falls
//   by at least 16 MB and the kept objects keep their bytes.
//
// Each check prints a SMOKE line. The result is false when one fails.
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

const _mb = 1 << 20;

/// Runs the checks of release prismarine1 with [log] for SMOKE lines. Returns
/// true when all pass.
bool releasePrismarine1Checks(void Function(String) log) {
  if (!gpu.prismarineOldSpaceSupported) {
    log('SMOKE release prismarine1 not on this engine (no PrismarineOldSpace)');
    return true;
  }
  var ok = true;
  void say(String name, String? problem) {
    log('SMOKE release prismarine1 $name: ${problem ?? 'ok'}');
    if (problem != null) ok = false;
  }

  try {
    final f = [for (var i = 0; i < 5; i++) gpu.prismarineHeap(i)];
    say(
      'heap figures',
      f[0] <= 0 || f[1] < f[0]
          ? 'old space used ${f[0]}, capacity ${f[1]}'
          : f[4] <= 0 || f[4] < f[3]
          ? 'new space used ${f[3]}, capacity ${f[4]}'
          : f[2] < 0
          ? 'old space external ${f[2]}'
          : gpu.prismarineHeap(5) != -1
          ? 'figure 5 is ${gpu.prismarineHeap(5)}, want -1'
          : null,
    );
  } on Object catch (e) {
    say('heap figures', '$e');
  }
  try {
    // A compaction first leaves no mark running.
    gpu.prismarineOldSpace(2);
    final ran = gpu.prismarineOldSpace(1);
    say('mark started', ran == 1 ? null : 'ran $ran, want 1');
    gpu.prismarineOldSpace(2);
  } on Object catch (e) {
    say('mark started', '$e');
  }
  try {
    // Two young collections promote the objects to the old space.
    const count = 64 * _mb ~/ 256;
    final objects = List<Uint8List?>.generate(
      count,
      (i) => Uint8List(232)..fillRange(0, 232, i & 0xFF),
    );
    gpu.prismarineOldSpace(2);
    gpu.prismarineOldSpace(2);
    for (var i = 1; i < count; i += 2) {
      objects[i] = null;
    }
    final before = gpu.prismarineHeap(1);
    final ran = gpu.prismarineOldSpace(2);
    final after = gpu.prismarineHeap(1);
    var kept = true;
    for (var i = 0; i < count && kept; i += 2) {
      final o = objects[i]!;
      kept = o[0] == i & 0xFF && o[231] == i & 0xFF;
    }
    log(
      'SMOKE release prismarine1 old space capacity ${before ~/ _mb} MB '
      'before the compaction, ${after ~/ _mb} MB after',
    );
    say(
      'compaction',
      ran != 2
          ? 'ran $ran, want 2'
          : before - after < 16 * _mb
          ? 'the capacity fell by ${(before - after) ~/ _mb} MB, want 16 MB'
          : !kept
          ? 'a kept object lost its bytes'
          : null,
    );
    objects.clear();
  } on Object catch (e) {
    say('compaction', '$e');
  }
  return ok;
}
