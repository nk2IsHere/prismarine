import 'dart:io';

import 'package:prismarine_cook/prismarine_cook.dart';

import 'engine_fetch.dart';
import 'toolchain.dart';

/// One result of a check of doctor.
class Finding {
  Finding.ok(this.what, this.detail) : problem = false, fix = null;
  Finding.problem(this.what, this.detail, this.fix) : problem = true;

  /// The thing checked, such as `Flutter` or `CMake`.
  final String what;

  /// The version or place found, or the cause of the problem.
  final String detail;
  final bool problem;

  /// The command or action that fixes a problem.
  final String? fix;
}

/// Runs a command and returns its output, or null when it cannot start or
/// fails.
typedef Reader = String? Function(List<String> command);

/// The checks of the toolchain of the computer, for [os] `macos`, `linux`
/// or `windows`.
class ToolchainChecks {
  ToolchainChecks(
    this.toolchain,
    this.read, {
    required this.os,
    required this.env,
    bool Function(String path)? exists,
  }) : exists = exists ?? ((p) => File(p).existsSync());

  final Toolchain toolchain;
  final Reader read;
  final String os;
  final Map<String, String> env;
  final bool Function(String path) exists;

  /// Every check of the toolchain. [release] is the engine release of the
  /// app, or null when none is known.
  List<Finding> all(EngineRelease? release) => [
    flutter(release),
    git(),
    ...rust(),
    if (os == 'macos') ...xcode(),
    if (os == 'linux') ...linuxPackages(),
    if (os == 'windows') visualStudio(),
    cmake(),
  ];

  Finding flutter(EngineRelease? release) {
    final root = toolchain.flutterRoot;
    if (root == null) {
      return Finding.problem(
        'Flutter',
        'no Flutter SDK in PRISMARINE_FLUTTER, ~/.prismarine/flutter or on PATH',
        Toolchain.installCommand(env),
      );
    }
    final v = toolchain.version;
    if (v != flutterVersion) {
      return Finding.problem(
        'Flutter',
        'the SDK in $root is ${v ?? 'of an unknown version'}, prismarine needs $flutterVersion',
        'git -C "$root" fetch --tags && git -C "$root" checkout $flutterVersion',
      );
    }
    final rev = toolchain.engineRevision;
    if (release != null && rev != null && !rev.startsWith(release.revision)) {
      return Finding.problem(
        'Flutter',
        'the SDK in $root has engine $rev, the release ${release.tag} is for ${release.revision}',
        'git -C "$root" checkout $flutterVersion',
      );
    }
    return Finding.ok('Flutter', '$v in $root');
  }

  Finding git() => read(['git', '--version']) == null
      ? Finding.problem('git', 'no git on PATH', switch (os) {
          'macos' => 'xcode-select --install',
          'linux' => 'sudo apt install git',
          _ => 'winget install Git.Git',
        })
      : Finding.ok(
          'git',
          read(['git', '--version'])!.replaceFirst('git version ', ''),
        );

  String? get _home {
    try {
      return homeDir(env);
    } on StateError {
      return null;
    }
  }

  /// The cargo on `PATH` or in `~/.cargo/bin`, or null.
  String? get cargo {
    if (read(['cargo', '--version']) != null) return 'cargo';
    try {
      final c =
          '${homeDir(env)}/.cargo/bin/cargo${os == 'windows' ? '.exe' : ''}';
      return exists(c) ? c : null;
    } on StateError {
      return null;
    }
  }

  List<Finding> rust() {
    final c = cargo;
    if (c == null) {
      return [
        Finding.problem(
          'Rust',
          'no cargo on PATH or in ~/.cargo/bin',
          os == 'windows'
              ? 'run rustup-init.exe from https://rustup.rs with its MSVC toolchain'
              : "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
        ),
      ];
    }
    final version = read([c, '--version']) ?? 'cargo';
    final home = _home;
    final rustupHome = env['RUSTUP_HOME'];
    if (home != null &&
        rustupHome != null &&
        rustupHome.isNotEmpty &&
        !exists('$home/.rustup/settings.toml')) {
      return [
        Finding.problem(
          'Rust',
          'rustup is in RUSTUP_HOME=$rustupHome, which a build hook does not get',
          os == 'windows'
              ? 'mklink /J "$home\\.rustup" "$rustupHome"'
              : 'ln -s "$rustupHome" ~/.rustup',
        ),
      ];
    }
    final rustup = c == 'cargo'
        ? 'rustup'
        : c.replaceFirst(RegExp(r'cargo(\.exe)?$'), 'rustup');
    final installed = read([rustup, 'target', 'list', '--installed']);
    final need = switch (os) {
      'macos' => ['aarch64-apple-darwin', 'x86_64-apple-darwin'],
      'windows' => [
        env['PROCESSOR_ARCHITECTURE'] == 'ARM64'
            ? 'aarch64-pc-windows-msvc'
            : 'x86_64-pc-windows-msvc',
      ],
      _ => <String>[],
    };
    final rust = Finding.ok('Rust', version.replaceFirst('cargo ', ''));
    if (installed == null || need.isEmpty) return [rust];
    final have = installed.split(RegExp(r'\s+')).toSet();
    final missing = need.where((t) => !have.contains(t)).toList();
    return [
      rust,
      if (missing.isEmpty)
        Finding.ok('Rust targets', need.join(', '))
      else
        Finding.problem(
          'Rust targets',
          'missing ${missing.join(', ')}',
          'rustup target add ${missing.join(' ')}',
        ),
    ];
  }

  Finding cmake() {
    final v = read(['cmake', '--version']);
    if (v != null) {
      return Finding.ok(
        'CMake',
        v.split('\n').first.replaceFirst('cmake version ', ''),
      );
    }
    if (os == 'windows' && _visualStudio != null) {
      return Finding.ok('CMake', 'the one of Visual Studio');
    }
    return Finding.problem('CMake', 'no cmake on PATH', switch (os) {
      'macos' => 'brew install cmake',
      'linux' => 'sudo apt install cmake',
      _ =>
        'install the workload "Desktop development with C++" of Visual Studio 2022',
    });
  }

  List<Finding> xcode() {
    final v = read(['xcodebuild', '-version']);
    if (v == null) {
      return [
        Finding.problem(
          'Xcode',
          'no Xcode, or the command-line tools are selected in its place',
          'install Xcode from the App Store, then sudo xcode-select -s /Applications/Xcode.app',
        ),
      ];
    }
    final metal = read(['xcrun', '-sdk', 'macosx', '-f', 'metal']);
    return [
      Finding.ok('Xcode', v.split('\n').first.replaceFirst('Xcode ', '')),
      if (metal == null)
        Finding.problem(
          'Metal compiler',
          'Xcode has no Metal toolchain, the shaders would compile at run time',
          'xcodebuild -downloadComponent MetalToolchain',
        )
      else
        Finding.ok('Metal compiler', metal),
    ];
  }

  List<Finding> linuxPackages() {
    const tools = {
      'clang++': 'clang',
      'ninja': 'ninja-build',
      'pkg-config': 'pkg-config',
      'xz': 'xz-utils',
    };
    const libs = {
      'gtk+-3.0': 'libgtk-3-dev',
      'alsa': 'libasound2-dev',
      'liblzma': 'liblzma-dev',
    };
    final missing = <String>[];
    for (final MapEntry(:key, :value) in tools.entries) {
      if (read([key, '--version']) == null) missing.add(value);
    }
    final pkg = read(['pkg-config', '--version']) != null;
    for (final MapEntry(:key, :value) in libs.entries) {
      if (!pkg || read(['pkg-config', '--exists', key]) == null) {
        missing.add(value);
      }
    }
    if (missing.isEmpty) {
      return [
        Finding.ok('Linux packages', 'build tools, GTK 3, ALSA and LZMA'),
      ];
    }
    return [
      Finding.problem(
        'Linux packages',
        'missing ${missing.join(', ')}',
        'sudo apt install ${missing.join(' ')}',
      ),
    ];
  }

  String? get _visualStudio {
    final pf = env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final vswhere = '$pf\\Microsoft Visual Studio\\Installer\\vswhere.exe';
    if (!exists(vswhere)) return null;
    final p = read([
      vswhere,
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationPath',
    ]);
    return p == null || p.isEmpty ? null : p.split('\n').first.trim();
  }

  Finding visualStudio() {
    final vs = _visualStudio;
    if (vs == null) {
      return Finding.problem(
        'Visual Studio',
        'no Visual Studio 2022 with its C++ tools',
        'install the workload "Desktop development with C++" of Visual Studio 2022',
      );
    }
    return Finding.ok('Visual Studio', vs);
  }
}

/// The checks of the engine of [release] in the folder of [search].
List<Finding> engineChecks(
  EngineRelease release,
  EngineSearch search,
  Toolchain toolchain,
  Reader read,
  Map<String, String> env,
) {
  final e = search.engine;
  if (e == null) {
    final other = search.otherRelease == null
        ? ''
        : ', it holds ${search.otherRelease}';
    return [
      Finding.problem(
        'Engine',
        'no engine ${release.name} for ${search.target} in ${search.dir}$other',
        'prismarine engine',
      ),
      ...downloadChecks(release, read, env),
    ];
  }
  final missing = e.missingParts;
  if (missing.isNotEmpty) {
    return [
      Finding.problem(
        'Engine',
        'the engine in ${e.outPath} lacks ${missing.join(', ')}',
        e.fetched ? 'prismarine engine --force' : 'build the engine again',
      ),
    ];
  }
  final out = <Finding>[
    Finding.ok(
      'Engine',
      e.fetched
          ? '${release.name} in ${search.dir}/${search.target}'
          : 'built from the patches in ${e.src}, its patches are not compared with ${release.name}',
    ),
  ];
  final rev = toolchain.engineRevision;
  if (e.revision != null && rev != null && e.revision != rev) {
    out.add(
      Finding.problem(
        'Engine and SDK',
        'the engine is for Flutter engine ${e.revision}, the SDK has $rev',
        'git -C "${toolchain.flutterRoot}" checkout $flutterVersion',
      ),
    );
  }
  return out;
}

/// The checks of the download of [release], which are gh, its login and the
/// repository of the releases.
List<Finding> downloadChecks(
  EngineRelease release,
  Reader read,
  Map<String, String> env,
) {
  final archive = env['PRISMARINE_ENGINE_ARCHIVE'];
  if (archive != null && archive.isNotEmpty) {
    return [Finding.ok('Engine download', 'from the archive $archive')];
  }
  final out = <Finding>[];
  if (read(['gh', '--version']) == null) {
    out.add(
      Finding.problem(
        'GitHub CLI',
        'no gh on PATH, the engine download needs it',
        Platform.isMacOS
            ? 'brew install gh'
            : Platform.isWindows
            ? 'winget install GitHub.cli'
            : 'sudo apt install gh',
      ),
    );
  } else if ((env['GH_TOKEN'] ?? '').isEmpty &&
      read(['gh', 'auth', 'status']) == null) {
    out.add(
      Finding.problem(
        'GitHub CLI',
        'gh is not logged in and GH_TOKEN is not set',
        'gh auth login',
      ),
    );
  } else {
    out.add(Finding.ok('GitHub CLI', 'logged in'));
  }
  final repo = releaseRepository(release, env);
  out.add(
    repo == null
        ? Finding.problem(
            'Release repository',
            'PRISMARINE_ENGINE_REPO is not set',
            'export PRISMARINE_ENGINE_REPO=<owner>/<name> of the engine releases',
          )
        : Finding.ok('Release repository', repo),
  );
  return out;
}
