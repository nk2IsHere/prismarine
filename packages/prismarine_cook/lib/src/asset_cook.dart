import 'dart:io';

import 'hashing.dart';
import 'project.dart';
import 'stamp.dart';

/// The result of [cookAsset].
class AssetCook {
  AssetCook(this.step, this.out, {required this.current, this.adopted = false});
  final AssetStep step;

  /// The output folder of the step.
  final String out;

  /// True when the output was current and the step did not run.
  final bool current;

  /// True when an output without a stamp had every path of
  /// [AssetStep.exists] and was taken as current.
  final bool adopted;
}

/// An asset step whose command failed.
class AssetStepError implements Exception {
  AssetStepError(this.step, this.exitCode);
  final AssetStep step;
  final int exitCode;
  @override
  String toString() =>
      'assets ${step.id}: `${step.run.join(' ')}` exited with $exitCode.';
}

/// The key of the inputs of [step] in [project].
String assetKey(Project project, AssetStep step, String out) => hashInputs([
  'assets 1',
  ...step.command(out),
], trees: step.inputPaths(project));

/// The stamp of [step] in its output folder [out].
Stamp assetStamp(AssetStep step, String out) =>
    Stamp('$out/cook-${step.id}.json');

/// Runs [step] of [project] when its stamp is stale or [force] is set.
/// [run] runs a command in a folder and returns its exit code. Throws an
/// [AssetStepError] when the command fails.
Future<AssetCook> cookAsset(
  Project project,
  AssetStep step, {
  required Future<int> Function(List<String> command, String dir) run,
  Map<String, String>? environment,
  bool force = false,
}) async {
  final out = step.outDir(environment ?? Platform.environment);
  final stamp = assetStamp(step, out);
  final key = assetKey(project, step, out);
  if (!force && stamp.key == key) return AssetCook(step, out, current: true);
  if (!force &&
      stamp.key == null &&
      step.exists.isNotEmpty &&
      step.exists.every(
        (p) =>
            FileSystemEntity.typeSync('$out/$p') !=
            FileSystemEntityType.notFound,
      )) {
    stamp.write(key);
    return AssetCook(step, out, current: true, adopted: true);
  }
  stamp.delete();
  final code = await run(step.command(out), project.dir);
  if (code != 0) throw AssetStepError(step, code);
  stamp.write(key);
  return AssetCook(step, out, current: false);
}
