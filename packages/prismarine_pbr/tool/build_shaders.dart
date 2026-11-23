// Builds the shaders of the renderer into one bundle per backend and writes
// the interface of each shader.
//
//   dart tool/build_shaders.dart <out> [--impellerc=<path>] [--backend=<b>=<dir>]
//
// The output has `bundle/<dir>/Pbr.0.shaderbundle.gz` for each backend,
// Metal and Vulkan by default, and `records.json`. It needs the impellerc of
// the patched engine, by default PRISMARINE_IMPELLERC.
import 'dart:convert';
import 'dart:io';

import 'package:prismarine_shaders/prismarine_shaders.dart';

Future<void> main(List<String> args) async {
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.length != 1) {
    stderr.writeln('usage: dart tool/build_shaders.dart <out> [options]');
    exit(64);
  }
  String? opt(String n) => args
      .where((a) => a.startsWith('--$n='))
      .map((a) => a.substring(n.length + 3))
      .firstOrNull;
  final impellerc = opt('impellerc') ?? findImpellerc();
  if (impellerc == null) {
    stderr.writeln(
      'build_shaders: no impellerc. Set PRISMARINE_IMPELLERC to the '
      'impellerc of the patched engine.',
    );
    exit(2);
  }
  final backends = {
    for (final b in args.where((a) => a.startsWith('--backend=')))
      b.substring(10).split('=')[0]: b.substring(10).split('=')[1],
  };
  final out = Directory(rest.single)..createSync(recursive: true);
  final tool = File.fromUri(Platform.script).parent;
  final source = Directory('${tool.parent.path}/shaders/programs');
  final work = Directory('${out.path}/work');
  if (work.existsSync()) work.deleteSync(recursive: true);
  final records = <String, Object?>{};
  for (final f in source.listSync(recursive: true).whereType<File>()) {
    final rel = f.path.substring(source.path.length + 1);
    File('${work.path}/programs/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(f.readAsBytesSync());
    if (rel.split(Platform.pathSeparator).contains('bodies')) continue;
    final id = rel.replaceAll(Platform.pathSeparator, '/');
    final stage = switch (id.split('.').last) {
      'vert' => 'vertex',
      'comp' => 'compute',
      _ => 'pixel',
    };
    records[id] = shaderInterface(_expand(f, source), stage);
  }
  final report = await buildShaderBundles(
    work.path,
    ShaderBundleSettings(
      backends: backends.isEmpty
          ? const {'metal_desktop': 'metal', 'vulkan': 'vulkan'}
          : backends,
      impellercArgs: const ['--metal-version=2.3'],
    ),
    impellerc: impellerc,
  );
  if (report.failed.isNotEmpty) {
    for (final MapEntry(:key, :value) in report.failed.entries) {
      stderr.writeln('build_shaders: $key failed: $value');
    }
    exit(1);
  }
  final bundle = Directory('${out.path}/bundle');
  if (bundle.existsSync()) bundle.deleteSync(recursive: true);
  Directory('${work.path}/bundle').renameSync(bundle.path);
  work.deleteSync(recursive: true);
  File(
    '${out.path}/records.json',
  ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(records));
  stdout.writeln(
    'build_shaders: ${report.bundled} shaders, ${report.bytes} bytes per '
    'backend, in ${out.path}',
  );
}

/// The text of [f] with its includes in place, for the interface.
String _expand(File f, Directory root) => f.readAsStringSync().replaceAllMapped(
  RegExp(r'#include "([^"]+)"'),
  (m) => _expand(File('${root.path}/${m[1]}'), root),
);
