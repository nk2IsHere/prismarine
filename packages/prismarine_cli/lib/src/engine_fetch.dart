import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'doctor.dart';
import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';

/// Returns the repository of the engine releases, which has the form
/// `<owner>/<name>`. It is `PRISMARINE_ENGINE_REPO` of [env], else the line
/// that sets it in a `private/config/*.env` at or above the checkout of
/// [release]. Returns null when neither sets one.
String? releaseRepository(EngineRelease release, Map<String, String> env) {
  final set = env['PRISMARINE_ENGINE_REPO'];
  if (set != null && set.isNotEmpty) return set;
  var d = Directory(release.checkout).absolute;
  while (true) {
    final config = Directory('${d.path}/private/config');
    if (config.existsSync()) {
      final files =
          config
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.env'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        for (final l in f.readAsLinesSync().reversed) {
          final m = RegExp(
            r'''^PRISMARINE_ENGINE_REPO=["']?([^"']+)["']?\s*$''',
          ).firstMatch(l);
          if (m != null) return m[1];
        }
      }
    }
    if (d.parent.path == d.path) return null;
    d = d.parent;
  }
}

/// Downloads the archive of [release] for [target], checks its SHA-256 and
/// unpacks it into `<dir>/<target>` in place of the old engine. With
/// `PRISMARINE_ENGINE_ARCHIVE` set, it unpacks the archive at that path in
/// place of a download. That archive needs its `.sha256` file beside it.
/// The steps run with [toolchain], [tools] and [ui].
Future<Engine> fetchEngine(
  EngineRelease release,
  String dir,
  String target,
  Toolchain toolchain,
  Tools tools,
  Ui ui,
) async {
  final env = toolchain.environment;
  final asset = 'prismarine-engine-$target.tar.xz';
  final tmp = Directory('$dir/.fetch-$target')..createSync(recursive: true);
  try {
    final archive = env['PRISMARINE_ENGINE_ARCHIVE'];
    final file = File('${tmp.path}/$asset');
    final sum = File('${tmp.path}/$asset.sha256');
    if (archive != null && archive.isNotEmpty) {
      if (!File(archive).existsSync()) {
        throw Failure(
          'PRISMARINE_ENGINE_ARCHIVE is $archive, which does not exist.',
          fix: 'unset PRISMARINE_ENGINE_ARCHIVE',
        );
      }
      if (!File('$archive.sha256').existsSync()) {
        throw Failure(
          'The archive $archive has no $archive.sha256 beside it.',
          fix: 'download the .sha256 file of the archive into the same folder',
        );
      }
      File(archive).copySync(file.path);
      File('$archive.sha256').copySync(sum.path);
    } else {
      final problems = [
        for (final f in downloadChecks(release, tools.read, env))
          if (f.problem) f,
      ];
      if (problems.isNotEmpty) {
        throw Failure(
          'The engine ${release.name} cannot be downloaded: ${problems.first.detail}.',
          fix: problems.first.fix,
        );
      }
      final repo = releaseRepository(release, env)!;
      ui.status = 'downloading $asset';
      await tools.must(
        [
          'gh', 'release', 'download', release.tag, '-R', repo, //
          '-p', asset, '-p', '$asset.sha256', '-D', tmp.path, '--clobber',
        ],
        log: 'engine-download',
        cause: 'The download of $asset of ${release.tag} from $repo failed.',
        fix: 'gh release view ${release.tag} -R $repo',
      );
    }
    ui.status = 'checking the SHA-256';
    final want = sum.readAsStringSync().trim().split(RegExp(r'\s+')).first;
    final have = (await sha256.bind(file.openRead()).first).toString();
    if (want != have) {
      throw Failure(
        'The SHA-256 of $asset is $have, but its .sha256 file has $want.',
        fix: 'prismarine engine --force',
      );
    }
    ui.status = 'unpacking';
    final dest = Directory('$dir/$target');
    if (dest.existsSync()) dest.deleteSync(recursive: true);
    await tools.must(
      ['tar', '-C', dir, '-xJf', file.path],
      log: 'engine-unpack',
      cause: 'tar could not unpack $asset.',
      fix: Platform.isLinux ? 'sudo apt install xz-utils' : null,
    );
  } finally {
    tmp.deleteSync(recursive: true);
  }
  final search = findEngine(dir, target, release);
  final e = search.engine;
  if (e == null || !e.fetched) {
    throw Failure(
      'The archive of ${release.tag} holds no engine of that release for $target.',
      fix: 'gh release view ${release.tag}',
    );
  }
  linkDartSdk(e, toolchain);
  return e;
}

/// Links `dart-sdk` in the out folder of the fetched engine [e] to the
/// `dart-sdk` of [toolchain]. Both hold the same Dart.
void linkDartSdk(Engine e, Toolchain toolchain) {
  if (!e.fetched || toolchain.flutterRoot == null) return;
  final link = Link('${e.outPath}/dart-sdk');
  final want = toolchain.dartSdk;
  if (link.existsSync()) {
    if (link.targetSync() == want) return;
    link.deleteSync();
  } else if (Directory(link.path).existsSync()) {
    return;
  }
  link.createSync(want);
}
