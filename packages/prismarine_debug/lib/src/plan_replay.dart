import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_render/prismarine_render.dart';

/// Runs the frame plan in `<dir>/plan.json` with its blobs in `<dir>/blob/`
/// and of [format] on [runner]. Writes the first mip and layer of every
/// target as stored to `<dir>/<out>/<target>.bin`.
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
    // Each distinct content gets one object, since the codec keeps the
    // identity of a block. The files are per write and not per block.
    (name) => blobs[name] ??= () {
      final b = File('$dir/blob/$name').readAsBytesSync();
      return byContent[base64.encode(b)] ??= b;
    }(),
    format: format,
  );
  // The blocks of the plan are read from its files and do not change.
  runner
    ..warn = log
    ..keepBlocks = true
    // The targets are read back after the runs.
    ..keepStores = true;
  // Read-back buffers, such as the words of a compute pass, go to
  // `<dir>/readback/<name>.bin` with the bars of the name as underscores.
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
  // With PRISMARINE_REPLAY_BENCH=<n> the plan is recorded n times more, each
  // time after the last record is done on the GPU. The CPU time of the
  // record is printed. It is the time of a still frame, with every draw
  // recorded before.
  final bench = int.tryParse(
    Platform.environment['PRISMARINE_REPLAY_BENCH'] ??
        Platform.environment['MCSM_REPLAY_BENCH'] ??
        '',
  );
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
  // The read-backs arrive through an image after the frame completes.
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
      // With PRISMARINE_REPLAY_MIP=<m> the mip m of each target that has it
      // is written too, as `<target>[.L<layer>].M<m>.bin`.
      final mip = int.tryParse(
        Platform.environment['PRISMARINE_REPLAY_MIP'] ??
            Platform.environment['MCSM_REPLAY_MIP'] ??
            '',
      );
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
