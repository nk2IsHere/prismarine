import 'dart:io';

/// Returns the data directory of the sample: [flag] when it is given, else
/// `PRISMARINE_SAMPLE_DATA`, else `sample` in the prismarine folder of the
/// user, `~/.prismarine/sample` or `%LOCALAPPDATA%\prismarine\sample` on
/// Windows. The app and `tool/fetch.dart` share this default.
String sampleDataDir([String? flag]) {
  if (flag != null && flag.isNotEmpty) return flag;
  final env = Platform.environment;
  final set = env['PRISMARINE_SAMPLE_DATA'];
  if (set != null && set.isNotEmpty) return set;
  if (Platform.isWindows) {
    final local = env['LOCALAPPDATA'];
    if (local == null || local.isEmpty) {
      throw StateError(
        'No data directory. LOCALAPPDATA is not set. Pass --data=<dir> or '
        'set PRISMARINE_SAMPLE_DATA.',
      );
    }
    return '$local\\prismarine\\sample';
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'No data directory. HOME is not set. Pass --data=<dir> or set '
      'PRISMARINE_SAMPLE_DATA.',
    );
  }
  return '$home/.prismarine/sample';
}

/// The data directory holds no prepared scene.
class SampleDataMissing implements Exception {
  SampleDataMissing(this.dir);
  final String dir;

  @override
  String toString() =>
      'No prepared scene in $dir. Run `dart tool/fetch.dart` in '
      'apps/prismarine_sample to download and prepare it there, or pass '
      '--data=<dir> with a prepared scene.';
}
