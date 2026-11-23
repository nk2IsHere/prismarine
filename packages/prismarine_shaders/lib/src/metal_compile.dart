import 'dart:io';
import 'dart:typed_data';

import 'shader_bundle_split.dart';

/// Apple's Metal compiler, which compiles a bundle's MSL into the Metal
/// library the bundle carries (patch 0004's `compiled`): impellerc writes
/// only the source, which the engine would otherwise compile at run time.
class MetalCompiler {
  MetalCompiler._(this.metal, this.sdk);
  final String metal;
  final String sdk;

  /// The compiler xcrun names, or null off macOS or without the toolchain.
  static MetalCompiler? find() {
    if (!Platform.isMacOS) return null;
    final m = Process.runSync('xcrun', ['-sdk', 'macosx', '-f', 'metal']);
    final s = Process.runSync('xcrun', ['-sdk', 'macosx', '--show-sdk-path']);
    if (m.exitCode != 0 || s.exitCode != 0) return null;
    return MetalCompiler._(
      (m.stdout as String).trim(),
      (s.stdout as String).trim(),
    );
  }

  /// Checks that [msl] (written to [file]) compiles with [flags]
  /// ([metalCompileFlags]), without linking a library: null when it does,
  /// else the compiler's first error.
  Future<String?> check(Uint8List msl, String file, List<String> flags) async {
    File(file).writeAsBytesSync(msl);
    final r = await Process.run(metal, [
      '-isysroot',
      sdk,
      ...flags,
      '-w',
      '-c',
      file,
      '-o',
      '/dev/null',
    ]);
    return r.exitCode == 0 ? null : _firstError(r, file);
  }

  /// Compiles [msl] in [dir] with [flags] ([metalCompileFlags]): the
  /// library, or the compiler's first error. The library names its output
  /// file and takes its UUID from it, so the name is fixed: the same source
  /// gives the same bytes.
  Future<(Uint8List?, String?)> compile(
    Uint8List msl,
    String dir,
    List<String> flags,
  ) async {
    Directory(dir).createSync(recursive: true);
    final src = File('$dir/shader.metal')..writeAsBytesSync(msl);
    final lib = File('$dir/shader.metallib');
    if (lib.existsSync()) lib.deleteSync();
    final r = await Process.run(metal, [
      '-isysroot',
      sdk,
      ...flags,
      '-w',
      src.path,
      '-o',
      lib.path,
    ]);
    src.deleteSync();
    if (r.exitCode == 0 && lib.existsSync()) {
      final bytes = lib.readAsBytesSync();
      lib.deleteSync();
      return (bytes, null);
    }
    return (null, _firstError(r, src.path));
  }
}

String _firstError(ProcessResult r, String file) => '${r.stderr}'
    .split('\n')
    .firstWhere((l) => l.contains('error'), orElse: () => 'metal exit')
    .replaceFirst(file, '')
    .trim();

/// The compiler flags for a bundle entry with [options] (its
/// `metal_preserve_invariance` and `metal_safe_math`), as the engine
/// compiles its source at run time (patch 0021's compile options: MSL 2.3,
/// invariance, safe maths; none at all for an entry without options). The
/// SDK's macOS is the target, as the engine's own compile targets the
/// running system; an older macOS refuses the library and the engine
/// compiles the source instead (patch 0004).
List<String> metalCompileFlags(Map<String, Object> options) {
  final invariance = options['metal_preserve_invariance'] == true;
  final safe = options['metal_safe_math'] == true;
  if (!invariance && !safe) return const [];
  return [
    '-std=macos-metal2.3',
    if (invariance) '-fpreserve-invariance',
    if (safe) ...[
      '-fmetal-math-mode=safe',
      '-fmetal-math-fp32-functions=precise',
    ],
  ];
}

/// The uniform blocks [msl] really binds: `constant Name& x [[buffer(n)]]`.
List<String> metalBoundBlocks(Uint8List msl) {
  final text = String.fromCharCodes(msl);
  final found = {
    for (final m in RegExp(
      r'constant (\w+)&\s+\w+\s*\[\[buffer\(',
    ).allMatches(text))
      m[1]!,
  };
  return found.toList()..sort();
}

/// Each entry's `metal_desktop` source in an impellerc bundle.
Map<String, Uint8List> metalSources(Uint8List bundle) {
  final out = <String, Uint8List>{};
  final d = decodeShaderBundle(bundle) as List;
  for (final shader in (d[0] as List).cast<List?>()) {
    final mtl = shader?[shaderBundleBackends['metal_desktop']!] as List?;
    if (shader == null || mtl == null || mtl[5] == null) continue;
    out[String.fromCharCodes((shader[0] as List).cast<int>())] =
        Uint8List.fromList((mtl[5] as List).cast<int>());
  }
  return out;
}
