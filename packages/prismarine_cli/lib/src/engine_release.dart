import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'doctor.dart';
import 'engine_build.dart';
import 'engine_fetch.dart';
import 'tools.dart';
import 'ui.dart';

/// The files of an out folder that a release `flutter build --local-engine`
/// does not read. These are build files, object files, unstripped binaries, debug
/// symbols and the tools of the build alone.
bool _skipFile(String name) =>
    RegExp(
          r'(\.ninja|\.ninja\.d|\.d|\.stamp|\.TOC|\.json|\.gn|\.pdb|\.exp|\.ilk|\.dylib|\.a|\.tmp)$',
        ).hasMatch(name) &&
        name != 'flutter_windows.dll.exp' ||
    name == 'gn_logs.txt' ||
    name.startsWith('.') ||
    RegExp(
      r'^(flatc|analyze_snapshot|bootstrap_compile_platform|gen_snapshot_host_targeting_host|shader_archiver)',
    ).hasMatch(name) ||
    name.contains('_unittests');

const _dirs = [
  'FlutterMacOS.xcframework',
  'universal',
  'flutter_patched_sdk',
  'flutter_linux',
  'cpp_client_wrapper',
  'shader_lib',
];

/// Packs what a release `flutter build --local-engine` reads from the out
/// folder [out] of the engine sources [src] into
/// `<dest>/prismarine-engine-<target>.tar.xz` with its `.sha256`. [hostOut]
/// gives `sky_engine` and `const_finder` to a cross-built out folder that
/// lacks them. The archive holds `<target>/src/out/<out>/` and
/// `<target>/prismarine-engine.txt`. Returns the path of the archive.
Future<String> packageEngine({
  required Ui ui,
  required Tools tools,
  required EngineRelease release,
  required String src,
  required String out,
  required String target,
  required String dest,
  required String revision,
  String? hostOut,
}) => ui.step('package $target', () async {
  final from = Directory('$src/out/$out');
  if (!from.existsSync()) {
    throw Failure('No out folder $from.', fix: 'prismarine engine build');
  }
  final stage = Directory.systemTemp.createTempSync('prismarine-engine-pack');
  try {
    final to = Directory('${stage.path}/$target/src/out/$out')
      ..createSync(recursive: true);
    for (final e in from.listSync(followLinks: false)) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (e is File && !_skipFile(name)) {
        e.copySync('${to.path}/$name');
        await _keepMode(e.path, '${to.path}/$name');
      }
    }
    if (Platform.isWindows &&
        !File('${to.path}/flutter_windows.dll.pdb').existsSync()) {
      // The unpack step of the Flutter tool copies the debug symbols too, about 260 MB. An empty file stands in.
      File('${to.path}/flutter_windows.dll.pdb').createSync();
    }
    for (final d in _dirs) {
      if (Directory('${from.path}/$d').existsSync()) {
        await _copyTree('${from.path}/$d', '${to.path}/$d', tools);
      }
    }
    if (Platform.isWindows) {
      await _copyTree(
        '${from.path}/flutter_patched_sdk',
        '${to.path}/flutter_patched_sdk_product',
        tools,
      );
    } else {
      Link(
        '${to.path}/flutter_patched_sdk_product',
      ).createSync('flutter_patched_sdk');
    }
    for (final c in from.listSync().whereType<Directory>()) {
      final name = c.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('clang_')) continue;
      for (final g in c.listSync().whereType<File>()) {
        if (!g.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('gen_snapshot')) {
          continue;
        }
        Directory('${to.path}/$name').createSync();
        final dst =
            '${to.path}/$name/${g.path.split(Platform.pathSeparator).last}';
        g.copySync(dst);
        await _keepMode(g.path, dst);
      }
    }
    Directory('${to.path}/gen/dart-pkg').createSync(recursive: true);
    for (final g in ['dart-pkg/sky_engine', 'const_finder.dart.snapshot']) {
      for (final o in [from.path, '$src/out/${hostOut ?? out}']) {
        final p = '$o/gen/$g';
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.notFound) {
          continue;
        }
        if (FileSystemEntity.isDirectorySync(p)) {
          await _copyTree(p, '${to.path}/gen/$g', tools);
        } else {
          File(p).copySync('${to.path}/gen/$g');
        }
        break;
      }
    }
    final patchDir = '${release.checkout}/third_party/flutter_engine/patches';
    final names = [
      for (final f in Directory(patchDir).listSync().whereType<File>())
        if (f.path.endsWith('.patch'))
          f.path.split(Platform.pathSeparator).last,
    ]..sort();
    final all = <int>[
      for (final n in names) ...File('$patchDir/$n').readAsBytesSync(),
    ];
    File('${stage.path}/$target/prismarine-engine.txt').writeAsStringSync(
      'target=$target\n'
      'release=${release.tag}\n'
      'out=$out\n'
      'engine_revision=$revision\n'
      'patches=${names.join(' ')} \n'
      'patches_sha256=${sha256.convert(all).toString().substring(0, 12)}\n',
    );
    Directory(dest).createSync(recursive: true);
    final archive = '$dest/prismarine-engine-$target.tar.xz';
    if (Platform.isWindows) {
      await tools.must(
        ['tar', '-C', stage.path, '-cJf', archive, target],
        log: 'engine-package',
        cause: 'tar failed.',
      );
    } else {
      await tools.must(
        [
          'sh',
          '-c',
          'tar -C "\$1" -cf - "\$2" | xz -9 -T0 > "\$3"',
          'pack',
          stage.path,
          target,
          archive,
        ],
        log: 'engine-package',
        cause: 'tar or xz failed.',
        fix: Platform.isLinux ? 'sudo apt install xz-utils' : 'brew install xz',
      );
    }
    final sum = (await sha256.bind(File(archive).openRead()).first).toString();
    File(
      '$archive.sha256',
    ).writeAsStringSync('$sum  prismarine-engine-$target.tar.xz\n');
    return archive;
  } finally {
    stage.deleteSync(recursive: true);
  }
}, done: (a) => 'ok, $a (${(File(a).lengthSync() / 1e6).toStringAsFixed(1)} MB)');

Future<void> _copyTree(String from, String to, Tools tools) async {
  if (Platform.isWindows) {
    final r = await Process.run('robocopy', [
      from,
      to,
      '/E',
      '/NFL',
      '/NDL',
      '/NJH',
      '/NJS',
    ]);
    if (r.exitCode >= 8) throw Failure('The copy of $from failed: ${r.stdout}');
  } else {
    await tools.must(
      ['cp', '-pR', from, to],
      log: 'engine-package',
      cause: 'The copy of $from failed.',
    );
  }
}

Future<void> _keepMode(String from, String to) async {
  if (Platform.isWindows) return;
  final mode = File(from).statSync().mode & 0x1ff;
  await Process.run('chmod', [mode.toRadixString(8), to]);
}

/// Sets `RELEASE` of [checkout] and the constant of the engine check of
/// prismarine_scene to `engine-<12 digits of revision>-<name>`. Returns the
/// new tag.
String bumpRelease(String checkout, String revision, String name) {
  if (!RegExp(r'^[a-z][a-z0-9]*$').hasMatch(name)) {
    throw Failure(
      'The release name "$name" is not lower-case letters and digits.',
      fix: 'prismarine engine release prismarine2',
    );
  }
  final tag = 'engine-${revision.substring(0, 12)}-$name';
  File(
    '$checkout/third_party/flutter_engine/RELEASE',
  ).writeAsStringSync('$tag\n');
  final check = File(
    '$checkout/packages/prismarine_scene/lib/src/gpu/engine_check.dart',
  );
  check.writeAsStringSync(
    check.readAsStringSync().replaceFirst(
      RegExp(r"const prismarineEngineRelease = '[^']*';"),
      "const prismarineEngineRelease = '$tag';",
    ),
  );
  return tag;
}

/// Uploads the archives of [release] in [from] with their `.sha256` and a
/// `SHA256SUMS` of every archive of the release to its GitHub release,
/// which it creates when it is missing.
Future<String> publishEngine({
  required Ui ui,
  required Tools tools,
  required EngineRelease release,
  required String from,
  required Map<String, String> env,
}) => ui.step<String>('publish ${release.name}', () async {
  final repo = releaseRepository(release, env);
  if (repo == null) {
    throw Failure('PRISMARINE_ENGINE_REPO is not set.', fix: repoFix);
  }
  final archives = [
    for (final f in Directory(from).listSync().whereType<File>())
      if (RegExp(r'prismarine-engine-[a-z0-9-]+\.tar\.xz$').hasMatch(f.path))
        f.path,
  ]..sort();
  if (archives.isEmpty) {
    throw Failure(
      'No prismarine-engine-*.tar.xz in $from.',
      fix: 'prismarine engine package --dest=$from',
    );
  }
  final sums = <String, String>{};
  final exists =
      tools.read(['gh', 'release', 'view', release.tag, '-R', repo]) != null;
  if (exists) {
    final tmp = Directory.systemTemp.createTempSync('prismarine-sums');
    if (tools.read([
          'gh',
          'release',
          'download',
          release.tag,
          '-R',
          repo,
          '-p',
          'SHA256SUMS',
          '-D',
          tmp.path,
        ]) !=
        null) {
      for (final l in File('${tmp.path}/SHA256SUMS').readAsLinesSync()) {
        final p = l.split(RegExp(r'\s+'));
        if (p.length == 2) sums[p[1]] = p[0];
      }
    }
    tmp.deleteSync(recursive: true);
  }
  final files = <String>[];
  for (final a in archives) {
    final sum = File('$a.sha256');
    if (!sum.existsSync()) {
      throw Failure(
        '$a has no .sha256 beside it.',
        fix: 'prismarine engine package',
      );
    }
    final want = sum.readAsStringSync().trim().split(RegExp(r'\s+')).first;
    final have = (await sha256.bind(File(a).openRead()).first).toString();
    if (want != have) {
      throw Failure(
        '$a does not match its .sha256.',
        fix: 'prismarine engine package',
      );
    }
    sums[a.split(Platform.pathSeparator).last.split('/').last] = have;
    files.addAll([a, sum.path]);
  }
  final names = sums.keys.toList()..sort();
  final list = File('$from/SHA256SUMS')
    ..writeAsStringSync(
      '${[for (final n in names) '${sums[n]}  $n'].join('\n')}\n',
    );
  files.add(list.path);
  if (exists) {
    await tools.must(
      [
        'gh',
        'release',
        'upload',
        release.tag,
        '-R',
        repo,
        '--clobber',
        ...files,
      ],
      log: 'engine-publish',
      cause: 'The upload to ${release.tag} of $repo failed.',
    );
  } else {
    await tools.must(
      [
        'gh',
        'release',
        'create',
        release.tag,
        '-R',
        repo,
        '--title',
        release.tag,
        '--notes',
        'The patched engine ${release.name}.',
        ...files,
      ],
      log: 'engine-publish',
      cause: 'The creation of the release ${release.tag} in $repo failed.',
    );
  }
  return '${archives.length} archives to $repo';
}, done: (s) => s);

/// The target of an engine out folder with the out folder
/// of the host tools for a cross build.
(String target, String? hostOut) targetOf(String os, String cpu) =>
    ('$os-$cpu', (os != 'macos' && cpu == 'arm64') ? outName(os, 'x64') : null);
