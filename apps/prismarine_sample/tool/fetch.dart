// Downloads Intel's Sponza for the sample and prepares it for the GPU.
//
//   dart tool/fetch.dart [--out=<dir>] [--ivy] [--no-curtains]
//       [--texture-size=1024] [--jobs=<n>] [--keep-source]
//
// The default directory is PRISMARINE_SAMPLE_DATA, else data/sample of the
// repository. Only the glTF part of each archive is downloaded.
import 'dart:convert';
import 'dart:io';

import 'package:prismarine_assets/prismarine_assets.dart';

import 'src/remote_zip.dart';

/// The packages of the scene: a name, the download link and whether the
/// default fetch takes it.
const packages = [
  ('main', 'https://cdrdv2.intel.com/v1/dl/getContent/830833', true),
  ('curtains', 'https://cdrdv2.intel.com/v1/dl/getContent/726650', true),
  ('ivy', 'https://cdrdv2.intel.com/v1/dl/getContent/726656', false),
];

const sourcePage =
    'https://www.intel.com/content/www/us/en/developer/topic-technology/'
    'graphics-research/samples.html';

Future<void> main(List<String> args) async {
  String? opt(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final out = opt('out') ?? defaultDataDir();
  final textureSize = int.parse(opt('texture-size') ?? '1024');
  final jobs = int.parse(
    opt('jobs') ?? '${(Platform.numberOfProcessors ~/ 2).clamp(1, 8)}',
  );
  final want = [
    for (final (name, link, byDefault) in packages)
      if (args.contains('--$name') ||
          (byDefault && !args.contains('--no-$name')))
        (name, link),
  ];
  stdout.writeln(
    'fetch: Intel Sponza from $sourcePage, licensed CC BY 4.0. '
    'The credits are in each package\'s credits_license.txt.',
  );
  for (final (name, link) in want) {
    final source = '$out/source/$name';
    final gltf = await _download(name, link, source, jobs);
    final sw = Stopwatch()..start();
    final report = await prepareGltf(
      gltf,
      '$out/prepared/$name',
      textureSize: textureSize,
      jobs: jobs,
      log: (l) => stdout.writeln('prepare $name: $l'),
    );
    for (final s in report.skipped) {
      stdout.writeln('prepare $name: left out $s');
    }
    File(
      '$source/credits_license.txt',
    ).copySync('$out/prepared/$name/credits_license.txt');
    stdout.writeln(
      'prepare $name: ${report.chunks} chunks, ${report.textures} textures '
      'in ${sw.elapsed.inSeconds} s',
    );
    if (!args.contains('--keep-source')) {
      Directory(source).deleteSync(recursive: true);
    }
  }
  stdout.writeln('fetch: done, the scene is in $out/prepared');
}

/// The data directory of the sample: PRISMARINE_SAMPLE_DATA, else
/// data/sample of the repository that holds this tool.
String defaultDataDir() {
  final env = Platform.environment['PRISMARINE_SAMPLE_DATA'];
  if (env != null && env.isNotEmpty) return env;
  final tool = File.fromUri(Platform.script).parent;
  return '${tool.parent.parent.parent.path}/data/sample';
}

/// Downloads the glTF of package [name], its credits, its buffers and its
/// images into [dir]. Returns the path of the glTF.
Future<String> _download(String name, String link, String dir, int jobs) async {
  final zip = RemoteZip(link);
  try {
    final entries = await zip.entries();
    final gltf = entries.firstWhere(
      (e) => e.name.endsWith('.gltf'),
      orElse: () => throw StateError('$name: the archive has no glTF file'),
    );
    final root = gltf.name.substring(0, gltf.name.lastIndexOf('/') + 1);
    final byName = {for (final e in entries) e.name: e};
    Future<void> get(String rel) async {
      final e = byName['$root$rel'];
      if (e == null) throw StateError('$name: the archive has no $root$rel');
      final path = '$dir/$rel';
      final have = File(path);
      if (have.existsSync() && have.lengthSync() == e.size) return;
      final sw = Stopwatch()..start();
      await zip.download(e, path);
      stdout.writeln(
        'fetch $name: $rel, ${(e.compressed / 1e6).toStringAsFixed(1)} MB '
        'in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
      );
    }

    final gltfRel = gltf.name.substring(root.length);
    await get(gltfRel);
    await get('credits_license.txt');
    final json =
        jsonDecode(File('$dir/$gltfRel').readAsStringSync())
            as Map<String, Object?>;
    final files = <String>{
      for (final key in const ['buffers', 'images'])
        for (final item in (json[key] as List?) ?? const [])
          if ((item as Map)['uri'] case final String uri
              when !uri.startsWith('data:'))
            _clean(Uri.decodeComponent(uri)),
    }.toList();
    final total = files.fold<int>(
      0,
      (s, f) => s + (byName['$root$f']?.compressed ?? 0),
    );
    stdout.writeln(
      'fetch $name: ${files.length} files, '
      '${(total / 1e9).toStringAsFixed(2)} GB',
    );
    var next = 0;
    Future<void> worker() async {
      while (next < files.length) {
        await get(files[next++]);
      }
    }

    await Future.wait([for (var j = 0; j < jobs; j++) worker()]);
    return '$dir/$gltfRel';
  } finally {
    zip.close();
  }
}

String _clean(String rel) => rel.startsWith('./') ? rel.substring(2) : rel;
