import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'shader_bundle_split.dart';

/// The Metal compiler of Xcode. It compiles the MSL of a bundle into the
/// Metal library that the bundle carries in its `compiled` field. Without
/// the library the engine compiles the source at run time.
class MetalCompiler {
  MetalCompiler._(this.metal, this.sdk);
  final String metal;
  final String sdk;

  /// Finds the compiler through xcrun. Returns null on a system other than
  /// macOS or without the toolchain.
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

  /// Checks that [msl] compiles with [flags] from [metalCompileFlags]
  /// without linking a library. Writes the source to [file]. Returns null
  /// when it compiles, else the first error of the compiler.
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

  /// Compiles [msl] in [dir] with [flags] from [metalCompileFlags]. Returns
  /// the library or the first error of the compiler. The library takes its
  /// UUID from the name of its output file. The name is fixed and the same
  /// source gives the same bytes.
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

/// Returns the compiler flags for a bundle entry with [options], the same
/// flags as the compile of the engine at run time. `metal_preserve_invariance`
/// and `metal_safe_math` select MSL 2.3 with invariance and with safe maths.
/// An entry with neither gets no flags. The target is the macOS of the SDK.
/// An older macOS refuses the library and the engine then compiles the
/// source.
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

/// Returns the uniform blocks that [msl] binds, each of the form
/// `constant Name& x [[buffer(n)]]`.
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

/// Returns the `metal_desktop` source of each entry of an impellerc bundle.
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

/// Returns [msl] with each vertex output whose name ends in
/// `viewport_index` bound to the viewport index of Metal, or null when the
/// source has none. A draw then goes to that viewport of the viewport array
/// of the pass. The GLSL declares the output as `flat out uint
/// viewport_index`, which impellerc writes as a user output.
Uint8List? metalViewportIndex(Uint8List msl) {
  final text = utf8.decode(msl, allowMalformed: true);
  if (!_userViewportIndex.hasMatch(text)) return null;
  return utf8.encode(
    text.replaceAllMapped(
      _userViewportIndex,
      (m) => 'uint ${m[1]} [[viewport_array_index]]',
    ),
  );
}

final _userViewportIndex = RegExp(
  r'\b(?:uint|int)\s+(\w*viewport_index)\s*\[\[user\([^\]]*\)\]\]',
);
