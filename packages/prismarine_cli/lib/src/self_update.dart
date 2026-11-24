import 'dart:io';

/// The packages whose sources make up the command.
const _sources = ['prismarine_cli', 'prismarine_cook', 'prismarine_shaders'];

/// Set for the command that a rebuild starts. That command never rebuilds
/// again, so a test that stays true after the rebuild cannot start a chain of
/// commands that each hold a compiler's memory.
const _rebuilt = 'PRISMARINE_REBUILT';

/// Builds the kernel of the command again when it runs from a kernel file
/// that is older than its sources, then runs the new kernel with [args].
/// Returns its exit code, or null when the kernel is current or the command
/// does not run from a kernel file.
Future<int?> updateSelf(List<String> args) async {
  if (Platform.environment[_rebuilt] == '1') return null;
  final script = Platform.script.toFilePath();
  if (!script.endsWith('.dill')) return null;
  final kernel = File(script);
  final root = kernel.parent.parent.parent.path;
  final built = kernel.lastModifiedSync();
  final config = File('$root/.dart_tool/package_config.json');
  final lock = File('$root/pubspec.lock');
  final dart = Platform.resolvedExecutable;
  var stale = false;
  if (lock.existsSync() &&
      (!config.existsSync() ||
          lock.lastModifiedSync().isAfter(config.lastModifiedSync()))) {
    final r = await Process.run(dart, ['pub', 'get'], workingDirectory: root);
    if (r.exitCode != 0) {
      stderr.write(
        'prismarine: `dart pub get` failed in $root.\n${r.stdout}${r.stderr}',
      );
      return 1;
    }
    // pub get leaves an unchanged package config as it is, so the lock would
    // stay newer than it and every start would resolve again.
    if (config.existsSync()) config.setLastModifiedSync(DateTime.now());
    stale = true;
  }
  stale = stale || lock.existsSync() && lock.lastModifiedSync().isAfter(built);
  for (final p in _sources) {
    if (stale) break;
    for (final d in ['lib', 'bin']) {
      final dir = Directory('$root/packages/$p/$d');
      if (!dir.existsSync()) continue;
      if (dir
          .listSync(recursive: true)
          .any((f) => f is File && f.lastModifiedSync().isAfter(built))) {
        stale = true;
        break;
      }
    }
  }
  if (!stale) return null;
  final tmp = '${kernel.path}.$pid';
  final r = await Process.run(dart, [
    'compile',
    'kernel',
    '-o',
    tmp,
    'packages/prismarine_cli/bin/prismarine.dart',
  ], workingDirectory: root);
  if (r.exitCode != 0) {
    stderr.write(
      'prismarine: the build of the command failed.\n${r.stdout}${r.stderr}',
    );
    if (File(tmp).existsSync()) File(tmp).deleteSync();
    return 1;
  }
  File(tmp).renameSync(kernel.path);
  final p = await Process.start(
    dart,
    [kernel.path, ...args],
    environment: {_rebuilt: '1'},
    mode: ProcessStartMode.inheritStdio,
  );
  return p.exitCode;
}
