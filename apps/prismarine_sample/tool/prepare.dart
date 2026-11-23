// Prepares any glTF file for the sample, as fetch.dart prepares Sponza.
//
//   dart tool/prepare.dart <file.gltf|file.glb> <data dir> [--name=<name>]
//       [--texture-size=1024]
//
// The scene goes into <data dir>/prepared/<name>, by default the name of the
// file. Run the sample with --data=<data dir> to see it.
import 'dart:io';

import 'package:prismarine_assets/prismarine_assets.dart';

Future<void> main(List<String> args) async {
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.length != 2) {
    stderr.writeln('usage: dart tool/prepare.dart <gltf> <data dir> [options]');
    exit(64);
  }
  String? opt(String n) => args
      .where((a) => a.startsWith('--$n='))
      .map((a) => a.substring(n.length + 3))
      .firstOrNull;
  final file = rest[0];
  final base = file.split(Platform.pathSeparator).last;
  final name = opt('name') ?? base.substring(0, base.lastIndexOf('.'));
  final out = '${rest[1]}/prepared/$name';
  final report = await prepareGltf(
    file,
    out,
    textureSize: int.parse(opt('texture-size') ?? '1024'),
    log: (l) => stdout.writeln('prepare $name: $l'),
  );
  for (final s in report.skipped) {
    stdout.writeln('prepare $name: left out $s');
  }
  stdout.writeln(
    'prepare $name: ${report.chunks} chunks, ${report.textures} textures in '
    '$out',
  );
}
