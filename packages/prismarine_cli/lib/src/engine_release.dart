import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

import 'engine_build.dart';
import 'tools.dart';
import 'ui.dart';

/// The files of an out folder that a release `flutter build --local-engine`
/// does not read. These are build files, object files, unstripped binaries,
/// debug symbols and the tools that only the build of the engine uses.
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
/// is the out folder that provides `sky_engine` and `const_finder` when a
/// cross-built [out] lacks them. The archive holds `<target>/src/out/<out>/` and
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
}) => ui.step(
  'package $target',
  () async {
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
        // The Flutter tool copies this file when it unpacks the engine. The
        // debug symbols are about 260 MB, so an empty file takes their place.
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
          fix: Platform.isLinux
              ? 'sudo apt install xz-utils'
              : 'brew install xz',
        );
      }
      final sum = (await sha256.bind(File(archive).openRead()).first)
          .toString();
      File(
        '$archive.sha256',
      ).writeAsStringSync('$sum  prismarine-engine-$target.tar.xz\n');
      return archive;
    } finally {
      stage.deleteSync(recursive: true);
    }
  },
  done: (a) => 'ok, $a (${(File(a).lengthSync() / 1e6).toStringAsFixed(1)} MB)',
);

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
    if (r.exitCode >= 8) {
      throw Failure('robocopy could not copy $from: ${r.stdout}');
    }
  } else {
    await tools.must(
      ['cp', '-pR', from, to],
      log: 'engine-package',
      cause: 'cp could not copy $from.',
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
      'The release name "$name" must start with a letter and hold only lower-case letters and digits.',
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
  for (final app in Project.below(checkout)) {
    final f = File('$app/prismarine.yaml');
    f.writeAsStringSync(
      f.readAsStringSync().replaceFirst(
        RegExp(r'^engine: .*$', multiLine: true),
        'engine: $tag',
      ),
    );
  }
  return tag;
}

/// Returns the target of the engine for [os] and [cpu] and, for a cross build,
/// the out folder that holds the host tools.
(String target, String? hostOut) targetOf(String os, String cpu) =>
    ('$os-$cpu', (os != 'macos' && cpu == 'arm64') ? outName(os, 'x64') : null);
