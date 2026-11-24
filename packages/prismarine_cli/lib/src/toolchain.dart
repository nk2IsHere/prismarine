import 'dart:convert';
import 'dart:io';

import 'package:prismarine_cook/prismarine_cook.dart';

/// The Flutter SDK that prismarine needs.
const flutterVersion = '3.47.7';

/// The Flutter SDK, the pub cache and the environment of the tools.
class Toolchain {
  Toolchain._(this.flutterRoot, this.pubCache, this.environment);

  /// Finds the Flutter SDK. It is the one of the Dart that runs this command,
  /// then `PRISMARINE_FLUTTER`, then `~/.prismarine/flutter`, then the
  /// `flutter` on `PATH`. [flutterRoot] is null when none exists.
  factory Toolchain.find(Map<String, String> env) {
    final root =
        _sdkOfDart(Platform.resolvedExecutable) ??
        _sdkAt(env['PRISMARINE_FLUTTER']) ??
        _sdkAt(_tryHome(env, 'flutter')) ??
        _sdkOnPath(env);
    var cache = env['PRISMARINE_PUB_CACHE'];
    if (cache == null || cache.isEmpty) {
      final home = _tryHome(env, 'pub-cache');
      cache = home != null && Directory(home).existsSync() ? home : null;
    }
    final out = Map<String, String>.of(env);
    if (root != null) {
      final sep = Platform.isWindows ? ';' : ':';
      out['PATH'] = '$root${_s}bin$sep${env['PATH'] ?? ''}';
      out['FLUTTER_ROOT'] = root;
    }
    if (cache != null && Directory(cache).existsSync()) {
      // The real path keeps the paths in package configs and build caches
      // the same whether a folder is reached through a link or not.
      cache = Directory(cache).resolveSymbolicLinksSync();
    }
    if (cache != null) out['PUB_CACHE'] = cache;
    return Toolchain._(root, cache, out);
  }

  /// The root of the Flutter SDK, or null without one.
  final String? flutterRoot;

  /// The pub cache, or null for the default of pub.
  final String? pubCache;

  /// The environment of every tool.
  final Map<String, String> environment;

  String get flutter =>
      '$flutterRoot${_s}bin${_s}flutter${Platform.isWindows ? '.bat' : ''}';

  String get dart =>
      '$flutterRoot${_s}bin${_s}dart${Platform.isWindows ? '.bat' : ''}';

  /// The `dart-sdk` folder of the SDK.
  String get dartSdk => '$flutterRoot${_s}bin${_s}cache${_s}dart-sdk';

  /// The version of the SDK, such as `3.47.7`, or null when unknown.
  String? get version {
    try {
      final j = jsonDecode(
        File('$flutterRoot/bin/cache/flutter.version.json').readAsStringSync(),
      );
      return (j as Map)['frameworkVersion'] as String?;
    } on Object {
      final f = File('$flutterRoot/version');
      return f.existsSync() ? f.readAsStringSync().trim() : null;
    }
  }

  /// The engine revision of the SDK, or null when unknown.
  String? get engineRevision {
    final f = File('$flutterRoot/bin/internal/engine.version');
    return f.existsSync() ? f.readAsStringSync().trim() : null;
  }

  /// The command that installs the SDK where prismarine looks for it.
  static String installCommand(Map<String, String> env) {
    final dir = _tryHome(env, 'flutter') ?? '~/.prismarine/flutter';
    return 'git clone --branch $flutterVersion '
        'https://github.com/flutter/flutter.git "$dir"';
  }
}

final _s = Platform.pathSeparator;

String? _tryHome(Map<String, String> env, String name) {
  try {
    return '${prismarineHome(env)}$_s$name';
  } on StateError {
    return null;
  }
}

String? _sdkAt(String? dir) {
  if (dir == null || dir.isEmpty) return null;
  final f = File('$dir${_s}bin${_s}flutter${Platform.isWindows ? '.bat' : ''}');
  if (!f.existsSync()) return null;
  return Directory(dir).resolveSymbolicLinksSync();
}

/// The SDK of the Dart at [exe], `<sdk>/bin/cache/dart-sdk/bin/dart`.
String? _sdkOfDart(String exe) {
  final parts = File(exe).absolute.path.split(RegExp(r'[/\\]'));
  final i = parts.lastIndexOf('dart-sdk');
  if (i < 2 || parts[i - 1] != 'cache' || parts[i - 2] != 'bin') return null;
  return _sdkAt(parts.sublist(0, i - 2).join(_s));
}

String? _sdkOnPath(Map<String, String> env) {
  final sep = Platform.isWindows ? ';' : ':';
  for (final d in (env['PATH'] ?? '').split(sep)) {
    if (d.isEmpty) continue;
    final sdk = _sdkAt(Directory(d).parent.path);
    if (sdk != null &&
        File(
          '$d${_s}flutter${Platform.isWindows ? '.bat' : ''}',
        ).existsSync()) {
      return sdk;
    }
  }
  return null;
}
