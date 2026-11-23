// The GPU pass log (`MCSM_GPU_PASS_LOG=<file>`, a debug tool): one line per
// renderer command buffer as it is submitted — its submission id, the time
// (Timeline.now, µs) and the pass that submitted it (the first stack frame
// outside the submission tracker) — and an `F` line at each display frame.
// flutter_scene submits each render pass in a command buffer of its own, in
// order, so a Metal System Trace's command buffers (ids in creation order)
// can be named pass by pass (tools/profiler/gpu_trace.sh, gpu_passes.py).
// On the mcsm7 engine (mcsmPassesPerCommandBuffer) the glow, DOF and SMAA
// chains, the occlusion prepass's two passes and the occlusion filter's two
// each share one command buffer, so such a line names the code that
// submitted several passes; the trace shows them as encoders inside it.
import 'dart:developer';
import 'dart:io';

import 'package:flutter/scheduler.dart';

/// Opens the log at [path] and writes an `F` line at each display frame.
/// Returns the function to call with each command buffer's submission id as
/// it is submitted. [skip] holds the file names of the submission tracker,
/// whose stack frames are passed over.
void Function(int id) installGpuPassLog(
  String path, {
  List<String> skip = const [],
}) {
  // Written line by line (a capture exits without a last frame callback).
  final out = File(path).openSync(mode: FileMode.write);
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    out.writeStringSync('F ${Timeline.now}\n');
  });
  return (id) {
    out.writeStringSync(
      'S $id ${Timeline.now} ${_pass(StackTrace.current, skip)}\n',
    );
  };
}

final _frame = RegExp(r'#\d+\s+(\S+)\s+\((\S+?)(?::\d+(?::\d+)?)?\)');

/// The first frame outside [skip], this file and the SDK.
String _pass(StackTrace st, List<String> skip) {
  for (final m in _frame.allMatches(st.toString())) {
    final fn = m.group(1)!, file = m.group(2)!;
    if (skip.any(file.contains) ||
        file.contains('gpu_pass_log.dart') ||
        file.startsWith('dart:')) {
      continue;
    }
    return '$fn@${file.split('/').last}';
  }
  return '?';
}
