import 'dart:convert';
import 'dart:io';

import 'package:prismarine_cook/prismarine_cook.dart';

import 'toolchain.dart';
import 'tools.dart';
import 'ui.dart';

/// The build of the patched engine from the patches in
/// `third_party/flutter_engine/patches` of a prismarine checkout, in the
/// tree `<engine dir>/flutter`.
class EngineBuild {
  EngineBuild(this.ui, this.tools, this.toolchain, this.checkout, this.dir);

  final Ui ui;
  final Tools tools;
  final Toolchain toolchain;

  /// The prismarine checkout with the patches.
  final String checkout;

  /// The engine folder, which holds `depot_tools` and the tree `flutter`.
  final String dir;

  String get patches => '$checkout/third_party/flutter_engine/patches';
  String get tree => '$dir/flutter';
  String get src => '$tree/engine/src';
  String get dartTree => '$src/flutter/third_party/dart';

  /// The engine revision of the Flutter SDK, which the patches apply to.
  String get revision {
    final r = toolchain.engineRevision;
    if (r == null) {
      throw Failure(
        'The Flutter SDK has no bin/internal/engine.version.',
        fix: Toolchain.installCommand(toolchain.environment),
      );
    }
    return r;
  }

  Map<String, String> get _env {
    final sep = Platform.isWindows ? ';' : ':';
    return {
      'PATH':
          '$dir${Platform.pathSeparator}depot_tools$sep'
          '${toolchain.environment['PATH'] ?? ''}',
      'DEPOT_TOOLS_METRICS': '0',
      if (Platform.isWindows) ...{
        'DEPOT_TOOLS_WIN_TOOLCHAIN': '0',
        'GYP_MSVS_OVERRIDE_PATH': ?_vsPath,
        'vs2022_install': ?_vsPath,
      },
    };
  }

  String? get _vsPath {
    const p = r'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools';
    return Directory(p).existsSync() ? p : null;
  }

  Future<ToolResult> _run(
    List<String> c, {
    String? dir,
    required String log,
    required String cause,
    String? fix,
  }) => tools.must(
    c,
    dir: dir,
    log: log,
    cause: cause,
    fix: fix,
    extraEnvironment: _env,
  );

  /// Installs depot_tools, clones Flutter at the engine revision on the
  /// branch `prismarine-engine` and fetches the dependencies of the engine
  /// for this OS with gclient. A tree that exists keeps its commits.
  Future<void> setup() async {
    Directory(dir).createSync(recursive: true);
    await ui.step('depot_tools', () async {
      if (Directory('$dir/depot_tools').existsSync()) return 'present';
      await _run(
        [
          'git', 'clone', '-q', '--depth', '1', //
          'https://chromium.googlesource.com/chromium/tools/depot_tools.git',
          'depot_tools',
        ],
        dir: dir,
        log: 'engine-depot-tools',
        cause: 'The clone of depot_tools failed.',
      );
      return 'cloned';
    }, done: (s) => s);
    await ui.step('flutter tree', () async {
      if (Directory('$tree/.git').existsSync()) return 'present in $tree';
      final sdk = toolchain.flutterRoot!;
      final shared = Directory('$sdk/.git').existsSync();
      await _run(
        [
          'git', 'clone', '-q', //
          if (shared) ...[
            '--shared',
            '--no-checkout',
            sdk,
          ] else ...[
            '--filter=blob:none',
            '--no-checkout',
            'https://github.com/flutter/flutter.git',
          ],
          'flutter',
        ],
        dir: dir,
        log: 'engine-clone',
        cause: 'The clone of Flutter failed.',
      );
      if (shared) {
        await _run(
          [
            'git',
            'remote',
            'set-url',
            'origin',
            'https://github.com/flutter/flutter.git',
          ],
          dir: tree,
          log: 'engine-clone',
          cause: 'The remote of the clone could not be set.',
        );
      }
      await _run(
        ['git', 'checkout', '-q', '-B', 'prismarine-engine', revision],
        dir: tree,
        log: 'engine-clone',
        cause: 'The checkout of revision $revision failed.',
      );
      return 'cloned at ${revision.substring(0, 12)}';
    }, done: (s) => s);
    File('$tree/.gclient').writeAsStringSync(gclientFile(hostPlatform()));
    await ui.step('gclient sync', () async {
      await _run(
        [_tool('gclient'), 'sync', '--no-history', '-j8'],
        dir: tree,
        log: 'engine-gclient',
        cause: '`gclient sync` failed.',
        fix: 'prismarine engine setup --verbose',
      );
    });
  }

  String _tool(String name) => Platform.isWindows
      ? '$dir\\depot_tools\\$name.bat'
      : '$dir/depot_tools/$name';

  /// Applies the patch files whose commits the tree lacks, then the Dart
  /// patches that the Dart SDK lacks. Returns the names of the applied
  /// files.
  Future<List<String>> patch() => ui.step(
    'patch',
    () async {
      if (!Directory('$tree/.git').existsSync()) {
        throw Failure(
          'No engine tree in $tree.',
          fix: 'prismarine engine setup',
        );
      }
      final log = tools.read([
        'git',
        '-C',
        tree,
        'log',
        '--format=%s',
        '$revision..HEAD',
      ]);
      if (log == null) {
        throw Failure(
          'The tree in $tree does not contain revision $revision.',
          fix: 'prismarine engine setup',
        );
      }
      final have = log.split('\n').map((s) => s.trim()).toSet();
      final files = _patchFiles(patches);
      final missing = [
        for (final f in files)
          if (!patchSubjects(File(f).readAsStringSync()).every(have.contains))
            f,
      ];
      final applied = <String>[];
      if (missing.isNotEmpty) {
        final email = tools.read([
          'git',
          '-C',
          checkout,
          'config',
          'user.email',
        ]);
        final name = tools.read(['git', '-C', checkout, 'config', 'user.name']);
        await _run(
          [
            'git', //
            '-c', 'user.name=${name ?? 'prismarine'}',
            '-c', 'user.email=${email ?? 'prismarine@localhost'}',
            '-c', 'core.autocrlf=false',
            'am', '-q', ...missing,
          ],
          dir: tree,
          log: 'engine-patch',
          cause: '`git am` of ${missing.map(_name).join(', ')} failed.',
          fix: 'git -C "$tree" am --abort, then fix the patch',
        );
        applied.addAll(missing.map(_name));
      }
      applied.addAll(await _patchDart());
      return applied;
    },
    done: (a) =>
        a.isEmpty ? 'every patch is in the tree' : 'applied ${a.join(', ')}',
  );

  /// Applies the Dart patches that the working tree of the Dart SDK lacks.
  /// The patches stay uncommitted at the Dart revision of `DEPS`. The
  /// engine stamps its Dart version from the HEAD of that checkout, which
  /// must stay the one that the kernel files of the Flutter tool carry.
  Future<List<String>> _patchDart() async {
    final files = _patchFiles('$patches/dart');
    if (files.isEmpty) return const [];
    final deps = File('$tree/DEPS').readAsStringSync();
    final rev = RegExp(
      r"^  'dart_revision': '([0-9a-f]+)',",
      multiLine: true,
    ).firstMatch(deps)?[1];
    if (rev == null) throw Failure('DEPS of $tree has no dart_revision.');
    final head = tools.read(['git', '-C', dartTree, 'rev-parse', 'HEAD']);
    if (head != rev) {
      await _run(
        ['git', 'checkout', '-q', '-f', '--detach', rev],
        dir: dartTree,
        log: 'engine-patch',
        cause: 'The checkout of Dart $rev failed.',
      );
    }
    final current = _treeOfWork();
    var done = -1;
    for (var k = files.length; k >= 0; k--) {
      if (_treeWith(files.sublist(0, k)) == current) {
        done = k;
        break;
      }
    }
    if (done < 0) {
      throw Failure(
        'The Dart SDK in $dartTree has changes that are not the Dart patches.',
        fix:
            'git -C "$dartTree" checkout -f $rev, then prismarine engine patch',
      );
    }
    final rest = files.sublist(done);
    if (rest.isEmpty) return const [];
    await _run(
      ['git', '-c', 'core.autocrlf=false', 'apply', ...rest],
      dir: dartTree,
      log: 'engine-patch',
      cause: '`git apply` of the Dart patches failed.',
    );
    return [for (final f in rest) 'dart/${_name(f)}'];
  }

  /// The tree id of the working tree of the Dart SDK with its changes.
  String _treeOfWork() {
    final index = '${Directory.systemTemp.path}/prismarine-index-$pid-w';
    final env = {...tools.environment, 'GIT_INDEX_FILE': index};
    try {
      Process.runSync(
        'git',
        ['read-tree', 'HEAD'],
        workingDirectory: dartTree,
        environment: env,
      );
      Process.runSync(
        'git',
        ['add', '-u'],
        workingDirectory: dartTree,
        environment: env,
      );
      return '${Process.runSync('git', ['write-tree'], workingDirectory: dartTree, environment: env).stdout}'
          .trim();
    } finally {
      if (File(index).existsSync()) File(index).deleteSync();
    }
  }

  /// The tree id of HEAD of the Dart SDK with the patches [files] applied.
  String? _treeWith(List<String> files) {
    final index = '${Directory.systemTemp.path}/prismarine-index-$pid-p';
    final env = {...tools.environment, 'GIT_INDEX_FILE': index};
    try {
      Process.runSync(
        'git',
        ['read-tree', 'HEAD'],
        workingDirectory: dartTree,
        environment: env,
      );
      if (files.isNotEmpty) {
        final r = Process.runSync(
          'git',
          ['apply', '--cached', ...files],
          workingDirectory: dartTree,
          environment: env,
        );
        if (r.exitCode != 0) return null;
      }
      return '${Process.runSync('git', ['write-tree'], workingDirectory: dartTree, environment: env).stdout}'
          .trim();
    } finally {
      if (File(index).existsSync()) File(index).deleteSync();
    }
  }

  /// Builds the release out folder of [cpu] with gn and ninja. Builds only
  /// the targets that a release `flutter build --local-engine` reads.
  Future<String> build(String cpu, {int? jobs}) {
    final os = hostPlatform();
    final out = outName(os, cpu);
    return ui.step('build $out', () async {
      if (!Directory(src).existsSync()) {
        throw Failure(
          'No engine sources in $src.',
          fix: 'prismarine engine setup',
        );
      }
      await _run(
        [
          if (Platform.isWindows) 'python3',
          'flutter${Platform.pathSeparator}tools${Platform.pathSeparator}gn',
          ...gnArgs(os, cpu),
        ],
        dir: src,
        log: 'engine-gn-$out',
        cause: 'gn failed for $out.',
      );
      final j =
          jobs ??
          (os == 'macos'
              ? 6
              : os == 'linux'
              ? 10
              : Platform.numberOfProcessors);
      await _run(
        [_tool('ninja'), '-C', 'out/$out', '-j$j', ...ninjaTargets(os, cpu)],
        dir: src,
        log: 'engine-ninja-$out',
        cause: 'ninja failed for $out.',
        fix: 'prismarine engine build --verbose',
      );
      final product = '$src/out/$out/flutter_patched_sdk_product';
      if (FileSystemEntity.typeSync(product, followLinks: false) ==
          FileSystemEntityType.notFound) {
        Link(product).createSync(
          Platform.isWindows
              ? '$src\\out\\$out\\flutter_patched_sdk'
              : 'flutter_patched_sdk',
        );
      }
      return out;
    }, done: (o) => 'ok, $src/out/$o');
  }
}

String _name(String path) => path.split(RegExp(r'[/\\]')).last;

List<String> _patchFiles(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.patch'))
      .toList()
    ..sort();
}

/// The subjects of the commits in the text of a patch file, without the
/// `[PATCH n/m]` prefix, as `git log --format=%s` gives them.
List<String> patchSubjects(String text) {
  final out = <String>[];
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('Subject: ')) continue;
    var s = lines[i].substring(9);
    while (i + 1 < lines.length && lines[i + 1].startsWith(' ')) {
      s += lines[++i];
    }
    out.add(s.replaceFirst(RegExp(r'^\[PATCH[^\]]*\]\s*'), '').trim());
  }
  return out;
}

/// The `.gclient` of the engine tree for [os], without Android, the JDK,
/// esbuild and Fuchsia.
String gclientFile(String os) => '''
solutions = [{
  "name": ".",
  "url": "https://github.com/flutter/flutter.git",
  "deps_file": "DEPS",
  "managed": False,
  "safesync_url": "",
  "custom_deps": {},
  "custom_vars": {
    "download_android_deps": False,
    "download_jdk": False,
    "download_esbuild": False,
    "download_fuchsia_deps": False,
    "setup_githooks": False,
  },
}]
${os == 'macos' ? '' : 'target_os = ["${os == 'windows' ? 'win' : 'linux'}"]\n'}''';

/// The out folder of a release engine for [os] and [cpu].
String outName(String os, String cpu) => switch ((os, cpu)) {
  ('linux', 'arm64') => 'linux_release_arm64',
  (_, 'arm64') => 'host_release_arm64',
  _ => 'host_release',
};

/// The arguments of gn for a release engine of [os] and [cpu].
List<String> gnArgs(String os, String cpu) => [
  '--runtime-mode=release',
  if (os == 'macos') '--mac-cpu=$cpu',
  if (os == 'linux' && cpu == 'arm64') ...[
    '--target-os=linux',
    '--linux-cpu=arm64',
  ],
  if (os == 'windows' && cpu == 'arm64') ...['--windows-cpu', 'arm64'],
  '--no-lto',
  '--prebuilt-dart-sdk',
  '--no-enable-unittests',
];

/// The ninja targets that a release `flutter build --local-engine` reads.
/// A cross-built arm64 engine of Linux or Windows leaves out the tools of
/// the host.
List<String> ninjaTargets(String os, String cpu) {
  const tools = [
    'flutter/sky/packages',
    'flutter/tools/font_subset',
    'flutter/tools/const_finder',
    'flutter/impeller/compiler:impellerc',
  ];
  return switch (os) {
    'macos' => [
      'flutter/shell/platform/darwin/macos:flutter_framework',
      'flutter/lib/snapshot:create_macos_gen_snapshots',
      'flutter/lib/snapshot:kernel_platform_files',
      'flutter/flutter_frontend_server:frontend_server',
      ...tools,
    ],
    'linux' => [
      'flutter/shell/platform/linux:flutter_gtk',
      'flutter/lib/snapshot:generate_snapshot_bins',
      'flutter/lib/snapshot:kernel_platform_files',
      if (cpu == 'x64') ...[
        'flutter/flutter_frontend_server:frontend_server',
        ...tools,
      ],
    ],
    _ => [
      'windows',
      'gen_snapshot',
      'flutter/build/archives:windows_flutter',
      'flutter/lib/snapshot:kernel_platform_files',
      if (cpu == 'x64') ...tools,
    ],
  };
}
