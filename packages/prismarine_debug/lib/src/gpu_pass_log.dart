// The GPU pass log writes one line per command buffer of the renderer as it
// is submitted, with its submission id, the time from Timeline.now in µs and
// the pass that submitted it. The pass is the first stack frame outside the
// submission tracker. An `F` line marks each display frame. A renderer that
// submits each render pass in a command buffer of its own, in order, lets
// the command buffers of a Metal System Trace be matched pass by pass. A
// command buffer shared by several passes gets the code that submitted them
// all. The trace shows the passes as encoders inside it.
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
  // The log is written line by line, since a capture exits without a last
  // frame callback.
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

/// Returns the first frame of [st] outside [skip], this file and the SDK.
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
