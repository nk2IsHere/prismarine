import 'dart:ffi';
import 'dart:io';

/// The engine target of the computer, such as `macos-arm64` or
/// `windows-x64`. Returns null on an OS or CPU without an engine release.
String? hostTarget() => switch (Abi.current()) {
  Abi.macosArm64 => 'macos-arm64',
  Abi.macosX64 => 'macos-x64',
  Abi.linuxX64 => 'linux-x64',
  Abi.linuxArm64 => 'linux-arm64',
  Abi.windowsX64 => 'windows-x64',
  Abi.windowsArm64 => 'windows-arm64',
  _ => null,
};

/// The Flutter platform of the computer, `macos`, `linux` or `windows`.
String hostPlatform() => Platform.isMacOS
    ? 'macos'
    : Platform.isWindows
    ? 'windows'
    : 'linux';

/// The out folder of a release engine of [target] in a tree built from the
/// patches.
String builtOutDir(String target) => switch (target) {
  'macos-arm64' || 'windows-arm64' => 'host_release_arm64',
  'linux-arm64' => 'linux_release_arm64',
  _ => 'host_release',
};

/// The home folder of the user, `USERPROFILE` on Windows and `HOME`
/// elsewhere. Throws a [StateError] when it is not set.
String homeDir(Map<String, String> env, {bool? windows}) {
  final w = windows ?? Platform.isWindows;
  final home = w ? env['USERPROFILE'] : env['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(w ? 'USERPROFILE is not set.' : 'HOME is not set.');
  }
  return home;
}

/// The folder of prismarine in the home folder, `~/.prismarine`. It holds
/// the Flutter SDK, the pub cache, the engine and the caches.
String prismarineHome(Map<String, String> env, {bool? windows}) {
  final w = windows ?? Platform.isWindows;
  return '${homeDir(env, windows: w)}${w ? r'\' : '/'}.prismarine';
}

/// The data folder of prismarine apps, `~/.prismarine`, or
/// `%LOCALAPPDATA%\prismarine` on Windows.
String dataHome(Map<String, String> env, {bool? windows}) {
  final w = windows ?? Platform.isWindows;
  if (!w) return prismarineHome(env, windows: false);
  final local = env['LOCALAPPDATA'];
  if (local == null || local.isEmpty) {
    throw StateError('LOCALAPPDATA is not set.');
  }
  return '$local\\prismarine';
}

/// The engine folder, `PRISMARINE_ENGINE_DIR` or `~/.prismarine/engine`.
String engineDir(Map<String, String> env, {bool? windows}) {
  final set = env['PRISMARINE_ENGINE_DIR'];
  if (set != null && set.isNotEmpty) return set;
  final w = windows ?? Platform.isWindows;
  return '${prismarineHome(env, windows: w)}${w ? r'\' : '/'}engine';
}

/// The folder of the shard cache of shader builds.
String shaderCacheDir(Map<String, String> env) =>
    '${prismarineHome(env)}/cache/shaders';
