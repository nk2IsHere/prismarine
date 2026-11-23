import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_render/prismarine_render.dart';

/// Runs the frame plan in `<dir>/plan.json` (blobs in `<dir>/blob/`), of
/// [format], on [runner] and writes every target's first mip and layer as
/// stored to `<dir>/<out>/<target>.bin`.
Future<void> replayPlan(
  String dir,
  FrameRunner runner, {
  required String format,
  String out = 'ours',
  required void Function(String) log,
}) async {
  final blobs = <String, Uint8List>{}, byContent = <String, Uint8List>{};
  final plan = planFromJson(
    jsonDecode(File('$dir/plan.json').readAsStringSync())
        as Map<String, Object?>,
    // One object per distinct content, as the codec keeps a block's identity
    // in play (the files name each write, not each block).
    (name) => blobs[name] ??= () {
      final b = File('$dir/blob/$name').readAsBytesSync();
      return byContent[base64.encode(b)] ??= b;
    }(),
    format: format,
  );
  // The plan's blocks are its own, read from its files: never changed.
  runner
    ..warn = log
    ..keepBlocks = true
    // Its targets are read back after the runs.
    ..keepStores = true;
  // Read-back buffers (an Enlighten duster pass's words) to
  // `<dir>/readback/<name>.bin`, the name's bars as underscores.
  final reads = <Future<void>>[];
  runner.onReadBack = (name, bytes) => reads.add(
    File(
      '$dir/readback/${name.replaceAll('|', '_')}.bin',
    ).create(recursive: true).then((f) => f.writeAsBytes(bytes)),
  );
  final sw = Stopwatch()..start();
  final ok = await runner.run(plan);
  log(
    'plan replay: ${plan.passes.length} passes, GPU ${ok ? 'done' : 'FAILED'} '
    'in ${sw.elapsedMilliseconds} ms (record ${_ms(runner.lastRecordMs)}: '
    'pipelines ${_ms(runner.lastPipelineMs)}, '
    'loads ${_ms(runner.lastLoadMs)}; GPU ${_ms(runner.lastGpuMs)})',
  );
  // MCSM_REPLAY_BENCH=<n>: the plan recorded n times more, each after
  // the last is done on the GPU, and the record's CPU time printed (a
  // still frame's: every draw recorded before).
  final bench = int.tryParse(Platform.environment['MCSM_REPLAY_BENCH'] ?? '');
  if (bench != null && bench > 0) {
    final record = <double>[], render = <double>[], compute = <double>[];
    final gpuOwn = <double>[];
    for (var i = 0; i < bench; i++) {
      await runner.run(plan);
      record.add(runner.lastRecordMs);
      render.add(runner.lastRenderMs);
      compute.add(runner.lastComputeMs);
      gpuOwn.add(runner.lastGpuOwnMs);
    }
    String p(List<double> v, double q) {
      final s = [...v]..sort();
      return s[(s.length * q).floor().clamp(0, s.length - 1)].toStringAsFixed(
        2,
      );
    }

    log(
      'plan replay bench: $bench runs, record p10 ${p(record, .1)} p50 '
      '${p(record, .5)} p90 ${p(record, .9)} ms (render p50 '
      '${p(render, .5)}, compute p50 ${p(compute, .5)}); GPU p50 '
      '${p(gpuOwn, .5)} p90 ${p(gpuOwn, .9)} ms',
    );
  }
  // The read-backs land after the frame's completion, through an image.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await Future.wait(reads);
  final outDir = Directory('$dir/$out')..createSync(recursive: true);
  for (final name in plan.targets.keys) {
    final spec = plan.targets[name]!;
    if (spec.samples > 1) continue;
    for (var layer = 0; layer < spec.layers; layer++) {
      final Uint8List bytes;
      try {
        bytes = await runner.readTarget(name, layer: layer);
      } catch (e) {
        log('plan replay: $name not read back: $e');
        break;
      }
      final suffix = spec.layers > 1 ? '.L$layer' : '';
      File('${outDir.path}/$name$suffix.bin').writeAsBytesSync(bytes);
      // MCSM_REPLAY_MIP=<m>: that mip of each target that has it too
      // (`<target>[.L<layer>].M<m>.bin`).
      final mip = int.tryParse(Platform.environment['MCSM_REPLAY_MIP'] ?? '');
      if (mip != null && mip > 0 && mip < spec.mips) {
        File('${outDir.path}/$name$suffix.M$mip.bin').writeAsBytesSync(
          await runner.readTarget(name, mip: mip, layer: layer),
        );
      }
    }
  }
  log('plan replay: targets in ${outDir.path}');
}

String _ms(double ms) => '${ms.toStringAsFixed(0)} ms';
