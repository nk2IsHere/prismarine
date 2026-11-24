import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'host.dart';
import 'project.dart';

/// A release of the patched engine, such as
/// `engine-deb287481e3c-prismarine1`.
class EngineRelease {
  EngineRelease(this.tag, this.file);

  /// Reads the release in the file [path]. Throws a [StateError] for a file
  /// that is missing or does not have the form `engine-<revision>-<name>`.
  factory EngineRelease.read(String path) {
    final f = File(path);
    if (!f.existsSync()) throw StateError('No release file at $path.');
    final tag = f.readAsStringSync().trim();
    if (!RegExp(r'^engine-[0-9a-f]{12}-\w+$').hasMatch(tag)) {
      throw StateError('$path holds "$tag", not engine-<revision>-<name>.');
    }
    return EngineRelease(tag, path);
  }

  final String tag;

  /// The file `RELEASE` that holds [tag].
  final String file;

  /// The first 12 hex digits of the engine revision of Flutter.
  String get revision => tag.split('-')[1];

  /// The short name, such as `prismarine1`.
  String get name => tag.substring(tag.indexOf('-', 7) + 1);

  /// The prismarine checkout that holds [file].
  String get checkout => File(file).parent.parent.parent.path;
}

/// The release file of the prismarine that the app in [appDir] resolves,
/// beside its vendored `flutter_gpu`. Returns null when the app has no
/// package config or does not use the vendored `flutter_gpu`.
String? releaseFileOfApp(String appDir) {
  final gpu = packageRootIn(appDir, 'flutter_gpu');
  if (gpu == null) return null;
  final f = File('$gpu/../flutter_engine/RELEASE');
  return f.existsSync() ? f.absolute.path : null;
}

/// A patched engine on disk.
class Engine {
  Engine({
    required this.src,
    required this.out,
    required this.fetched,
    this.release,
    this.revision,
  });

  /// The `src` folder that `--local-engine-src-path` takes.
  final String src;

  /// The out folder, such as `host_release_arm64`.
  final String out;

  /// True for an engine fetched from a release and false for one built
  /// from the patches.
  final bool fetched;

  /// The release of a fetched engine.
  final String? release;

  /// The full engine revision of a fetched engine.
  final String? revision;

  String get outPath => '$src/out/$out';

  String get impellerc =>
      '$outPath/impellerc${Platform.isWindows ? '.exe' : ''}';

  /// The flags of `flutter build` for this engine.
  List<String> get flutterArgs => [
    '--local-engine-src-path=$src',
    '--local-engine=$out',
    '--local-engine-host=$out',
  ];

  /// The parts of the out folder that a build needs and that are missing.
  List<String> get missingParts => [
    for (final p in [
      'flutter_patched_sdk_product',
      'impellerc${Platform.isWindows ? '.exe' : ''}',
    ])
      if (FileSystemEntity.typeSync('$outPath/$p') ==
          FileSystemEntityType.notFound)
        p,
    if (engineLibrary(outPath) == null) 'the engine library',
  ];
}

/// The result of a search for the engine of a release.
class EngineSearch {
  EngineSearch(this.engine, this.dir, this.target, this.otherRelease);

  /// The engine to build with, or null when none fits.
  final Engine? engine;

  /// The engine folder that was searched.
  final String dir;

  /// The target of the computer.
  final String target;

  /// The release of a fetched engine in the folder that is not the one
  /// searched for, or null.
  final String? otherRelease;
}

/// Finds the engine of [release] for [target] in the engine folder [dir].
/// A fetched engine of the release comes first, then a tree built from the
/// patches whose engine library has the exports of prismarine.
EngineSearch findEngine(String dir, String target, EngineRelease release) {
  final fetched = '$dir/$target';
  final info = readEngineInfo('$fetched/prismarine-engine.txt');
  if (info != null && info['release'] == release.tag) {
    return EngineSearch(
      Engine(
        src: '$fetched/src',
        out: info['out'] ?? builtOutDir(target),
        fetched: true,
        release: info['release'],
        revision: info['engine_revision'],
      ),
      dir,
      target,
      null,
    );
  }
  final built = Engine(
    src: '$dir/flutter/engine/src',
    out: builtOutDir(target),
    fetched: false,
  );
  final lib = engineLibrary(built.outPath);
  if (lib != null && fileContains(lib, prismarineExport)) {
    return EngineSearch(built, dir, target, info?['release']);
  }
  return EngineSearch(null, dir, target, info?['release']);
}

/// The export that every engine of prismarine has.
const prismarineExport = 'InternalFlutterGpu_PrismarineFeatures';

/// Reads the `key=value` lines of the info file of a fetched engine.
/// Returns null when it is missing.
Map<String, String>? readEngineInfo(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return {
    for (final l in f.readAsLinesSync())
      if (l.contains('='))
        l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
  };
}

/// The engine library in the out folder [out], or null when it has none.
String? engineLibrary(String out) {
  for (final p in [
    'libflutter_linux_gtk.so',
    'flutter_windows.dll',
    'FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework/FlutterMacOS',
    'FlutterMacOS.xcframework/macos-arm64/FlutterMacOS.framework/FlutterMacOS',
    'FlutterMacOS.xcframework/macos-x86_64/FlutterMacOS.framework/FlutterMacOS',
    'FlutterMacOS.framework/FlutterMacOS',
  ]) {
    if (File('$out/$p').existsSync()) return '$out/$p';
  }
  return null;
}

/// True when the bytes of the file [path] contain the ASCII text [text].
bool fileContains(String path, String text) {
  final needle = ascii.encode(text);
  final f = File(path).openSync();
  try {
    const chunk = 1 << 22;
    final buf = Uint8List(chunk + needle.length);
    var carry = 0;
    while (true) {
      final n = f.readIntoSync(buf, carry, carry + chunk);
      final end = carry + n;
      if (_indexOf(buf, end, needle) >= 0) return true;
      if (n == 0) return false;
      // Keeps the tail of this chunk in front of the next for a match that
      // spans both.
      final keep = end < needle.length - 1 ? end : needle.length - 1;
      buf.setRange(0, keep, buf, end - keep);
      carry = keep;
    }
  } finally {
    f.closeSync();
  }
}

int _indexOf(Uint8List hay, int end, List<int> needle) {
  final first = needle[0];
  final last = end - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    if (hay[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// The engine choice of the last command run in an app, which its build
/// hook reads. Flutter gives a hook no `PRISMARINE_ENGINE_DIR`.
class EngineChoice {
  EngineChoice(this.impellerc, this.release);

  final String impellerc;
  final String release;

  static String pathIn(String appDir) =>
      '$appDir/.dart_tool/prismarine/engine.json';

  void writeIn(String appDir) {
    final f = File(pathIn(appDir))..parent.createSync(recursive: true);
    final text = jsonEncode({'impellerc': impellerc, 'release': release});
    if (f.existsSync() && f.readAsStringSync() == text) return;
    f.writeAsStringSync(text);
  }

  /// Reads the choice of the app in [appDir], or null without one.
  static EngineChoice? readIn(String appDir) {
    try {
      final j = jsonDecode(File(pathIn(appDir)).readAsStringSync()) as Map;
      return EngineChoice(j['impellerc'] as String, j['release'] as String);
    } on Object {
      return null;
    }
  }
}
