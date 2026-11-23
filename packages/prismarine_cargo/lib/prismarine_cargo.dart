/// Builds the Rust crate of a package from its Dart build hook.
///
/// The `build` callback of a hook calls [buildCargoLibrary] with the
/// directory of the crate, as in `crate: 'native', library: 'example',
/// assetName: 'src/native.dart'`. Cargo builds the `cdylib` of the crate for
/// the target of the hook. The library ships as a bundled code asset.
/// `@Native` declarations for [assetName] resolve to it.
///
/// Cargo is found through `$CARGO`, `PATH` and then `~/.cargo/bin`. Each
/// target needs its Rust standard library, installed with
/// `rustup target add <triple>`. A macOS app build is universal and needs both
/// `aarch64-apple-darwin` and `x86_64-apple-darwin`. Windows builds use the
/// MSVC toolchain from the C++ build tools of Visual Studio. Linux builds
/// need a C compiler. A crate that links ALSA needs its headers from
/// `libasound2-dev`. A crate that builds C with CMake needs CMake. It is
/// found through `$CMAKE` and `PATH`, then through Homebrew and the CMake app
/// on macOS or as the CMake bundled with Visual Studio on Windows.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Builds [crate] in release mode for the hook with [input] and [output].
///
/// [crate] is the directory that holds `Cargo.toml`, as a path relative to
/// the package of the hook or as an absolute URI path. The build adds the
/// dynamic library [library], the `[lib] name` of the crate, as the code
/// asset `package:<package>/<assetName>`.
///
/// [extraSources] lists the files or directories outside the crate that its
/// build reads, such as vendored C that its `build.rs` compiles, relative to
/// the package. A change to one of them runs the hook again, as a change to
/// the sources of the crate does.
Future<void> buildCargoLibrary(
  BuildInput input,
  BuildOutputBuilder output, {
  required String crate,
  required String library,
  required String assetName,
  List<String> extraSources = const [],
}) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final triple = rustTriple(code.targetOS, code.targetArchitecture);
  final crateDir = input.packageRoot.resolve(
    crate.endsWith('/') ? crate : '$crate/',
  );
  // Every config of this package shares one cargo target directory. Cargo
  // keeps the targets apart in it.
  final targetDir = cargoTargetDir(
    input.outputDirectoryShared,
    windows: Platform.isWindows,
    environment: Platform.environment,
  );
  final cargo = _findCargo();
  // The build runs in a clean environment. The variables of an Xcode build,
  // such as SDKROOT, LD, ARCHS and the deployment targets, break the link of
  // rustc. rustup needs HOME or its own home variables. The linker needs
  // /usr/bin. Windows keeps the variables that rustc and the cc crate use to
  // find the linker and compiler of Visual Studio. Linux keeps the PATH of
  // the caller for its C compiler and the paths of pkg-config.
  final parent = Platform.environment;
  final cargoDir = File(cargo).parent.path;
  final env = <String, String>{
    'PATH': switch (Platform.operatingSystem) {
      'macos' => '$cargoDir:/usr/bin:/bin:/usr/sbin:/sbin',
      'windows' => '$cargoDir;${parent['PATH'] ?? ''}',
      _ => '$cargoDir:${parent['PATH'] ?? '/usr/bin:/bin'}',
    },
    for (final k in [
      'HOME',
      'TMPDIR',
      'RUSTUP_HOME',
      'CARGO_HOME',
      'RUSTUP_TOOLCHAIN',
      'SSH_AUTH_SOCK',
      'SYSTEMROOT',
      'TEMP',
      'TMP',
      if (Platform.isWindows) ...[
        'USERPROFILE',
        'LOCALAPPDATA',
        'APPDATA',
        'ProgramData',
        'ProgramFiles',
        'ProgramFiles(x86)',
        'ProgramW6432',
        'windir',
        'SystemDrive',
        'ComSpec',
        'PATHEXT',
        'NUMBER_OF_PROCESSORS',
        'PROCESSOR_ARCHITECTURE',
      ],
      if (Platform.isLinux) ...['PKG_CONFIG_PATH', 'PKG_CONFIG_SYSROOT_DIR'],
    ])
      if (parent[k] case final v?) k: v,
    // The `cmake` crate reads `CMAKE`. The PATH above leaves out the CMake of
    // Homebrew on macOS. Windows uses the CMake of Visual Studio.
    'CMAKE': ?_findCmake(),
    // The generator is the `CMAKE_GENERATOR` of the caller, else Ninja on
    // Linux with Ninja and without make, else the generator of the newest
    // Visual Studio on Windows. The cmake crate finds Visual Studio through
    // devenv.exe, which the Build Tools edition lacks. It then falls back to
    // NMake, which finds no compiler outside a developer prompt.
    'CMAKE_GENERATOR':
        ?(parent['CMAKE_GENERATOR'] ??
        (Platform.isLinux && !_onPath('make') && _onPath('ninja')
            ? 'Ninja'
            : Platform.isWindows
            ? _visualStudioGenerator()
            : null)),
    // Git dependencies are fetched with the git command line. It reads the
    // machine's git config, with its URL mappings and credentials.
    'CARGO_NET_GIT_FETCH_WITH_CLI': 'true',
    // The minimum macOS version of the app, for rustc and for the C code that
    // the build.rs of a crate compiles. Without it the cc crate targets the
    // version of the SDK.
    if (code.targetOS == OS.macOS) ...{
      'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}.0',
      // Host-side dylibs, such as proc-macros, are not stripped either. The
      // strip of Xcode 27 breaks them as it breaks the library below. rustc
      // then fails to load them.
      'CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP': 'none',
    },
  };

  final fileName = code.targetOS.libraryFileName(
    library,
    DynamicLoadingBundled(),
  );
  final result = await Process.run(
    cargo,
    [
      'rustc',
      '--release',
      '--lib',
      '--target',
      triple,
      '--manifest-path',
      crateDir.resolve('Cargo.toml').toFilePath(),
      '--target-dir',
      targetDir.toFilePath(),
      if (code.targetOS == OS.macOS) ...[
        '--',
        // The library is not stripped. The strip of Xcode 27, which the
        // default strip=debuginfo of the release profile runs, leaves the
        // LINKEDIT string pool 4-byte aligned when the indirect symbol table
        // has an odd count. dyld then refuses the dylib with "mis-aligned
        // LINKEDIT string pool". The profile has debug = false and leaves no
        // debug info to strip.
        '-C',
        'strip=none',
        // The app loads the library from its frameworks. The header pad
        // leaves room for Flutter to rewrite the install name.
        '-C',
        'link-arg=-Wl,-install_name,@rpath/$fileName',
        '-C',
        'link-arg=-Wl,-headerpad_max_install_names',
      ],
    ],
    // Cargo reads the config files of the crate's directory and its parents.
    workingDirectory: crateDir.toFilePath(),
    environment: env,
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      cargo,
      ['rustc', '--target', triple],
      'cargo failed for $crate ($triple):\n${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  final built = File.fromUri(targetDir.resolve('$triple/release/$fileName'));
  // Each config gets its own copy. Assets of different configs must not
  // share a file.
  final shipped = File.fromUri(input.outputDirectory.resolve(fileName));
  built.copySync(shipped.path);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: assetName,
      linkMode: DynamicLoadingBundled(),
      file: shipped.uri,
    ),
  );
  output.dependencies.addAll(_sources(crateDir));
  for (final extra in extraSources) {
    final uri = input.packageRoot.resolve(extra);
    final dir = Directory.fromUri(uri);
    if (dir.existsSync()) {
      output.dependencies.addAll([
        for (final f in dir.listSync(recursive: true))
          if (f is File) f.uri,
      ]);
    } else {
      output.dependencies.add(uri);
    }
  }
}

/// Returns the cargo target directory for the shared output directory
/// [shared] of a hook.
///
/// It is `cargo/` in [shared], except on Windows. There the try-compiles of
/// CMake under it exceed the path limit of 260 characters of MSBuild. On
/// Windows it is `prismarine\cargo\<hash>\` in `LOCALAPPDATA`, else in
/// `USERPROFILE\AppData\Local`, from [environment]. The hash of [shared]
/// keeps the directories of two packages or two checkouts apart.
Uri cargoTargetDir(
  Uri shared, {
  required bool windows,
  required Map<String, String> environment,
}) {
  if (!windows) return shared.resolve('cargo/');
  final local =
      environment['LOCALAPPDATA'] ??
      switch (environment['USERPROFILE']) {
        final home? => '$home\\AppData\\Local',
        null => null,
      };
  if (local == null) return shared.resolve('cargo/');
  return Uri.directory(
    '$local\\prismarine\\cargo\\${_hash(shared.toString())}',
    windows: true,
  );
}

/// The 32-bit FNV-1a hash of [s] in 8 hex digits.
String _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// Returns the Rust target triple of [os] and [arch].
String rustTriple(OS os, Architecture arch) => switch ((os, arch)) {
  (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
  (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
  (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
  (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
  (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
  (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
  _ => throw UnsupportedError('no Rust target for $os/$arch'),
};

String _findCargo() {
  final env = Platform.environment['CARGO'];
  if (env != null && File(env).existsSync()) return env;
  final exe = Platform.isWindows ? 'cargo.exe' : 'cargo';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(sep)) {
    if (dir.isEmpty) continue;
    final f = File('$dir${Platform.pathSeparator}$exe');
    if (f.existsSync()) return f.path;
  }
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
  final rustup = File(
    [home, '.cargo', 'bin', exe].join(Platform.pathSeparator),
  );
  if (rustup.existsSync()) return rustup.path;
  throw StateError('cargo not found (set CARGO, or install rustup)');
}

/// Returns the bin directory of the CMake bundled with the newest Visual
/// Studio, found with vswhere.
String? _visualStudioCmakeDir() {
  final pf =
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
  final vswhere = '$pf\\Microsoft Visual Studio\\Installer\\vswhere.exe';
  if (!File(vswhere).existsSync()) return null;
  try {
    final r = Process.runSync(vswhere, [
      '-latest',
      '-products',
      '*',
      '-property',
      'installationPath',
    ]);
    final root = '${r.stdout}'.trim().split('\n').first.trim();
    if (r.exitCode != 0 || root.isEmpty) return null;
    return '$root\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin';
  } on ProcessException {
    return null;
  }
}

/// Returns the CMake generator of the newest Visual Studio, such as "Visual
/// Studio 17 2022", found with vswhere. Returns null without Visual Studio.
String? _visualStudioGenerator() {
  final pf =
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
  final vswhere = '$pf\\Microsoft Visual Studio\\Installer\\vswhere.exe';
  if (!File(vswhere).existsSync()) return null;
  try {
    String? query(String property) {
      final r = Process.runSync(vswhere, [
        '-latest',
        '-products',
        '*',
        '-property',
        property,
      ]);
      final v = '${r.stdout}'.trim().split('\n').first.trim();
      return r.exitCode == 0 && v.isNotEmpty ? v : null;
    }

    final version = query('installationVersion');
    final year = query('catalog_productLineVersion');
    if (version == null || year == null) return null;
    return 'Visual Studio ${version.split('.').first} $year';
  } on ProcessException {
    return null;
  }
}

bool _onPath(String exe) {
  final sep = Platform.isWindows ? ';' : ':';
  return (Platform.environment['PATH'] ?? '')
      .split(sep)
      .any(
        (d) =>
            d.isNotEmpty &&
            File('$d${Platform.pathSeparator}$exe').existsSync(),
      );
}

/// Returns the path of CMake from `$CMAKE` or `PATH`, then from Homebrew and
/// the CMake app on macOS or from Visual Studio on Windows. Returns null when
/// none is found.
String? _findCmake() {
  final env = Platform.environment['CMAKE'];
  if (env != null && File(env).existsSync()) return env;
  final exe = Platform.isWindows ? 'cmake.exe' : 'cmake';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in [
    ...(Platform.environment['PATH'] ?? '').split(sep),
    if (Platform.isMacOS) ...[
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/Applications/CMake.app/Contents/bin',
    ],
    if (Platform.isWindows) ?_visualStudioCmakeDir(),
  ]) {
    if (dir.isEmpty) continue;
    final f = File('$dir${Platform.pathSeparator}$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Returns the manifest, lock file, build script and sources of the crate. A
/// change to one of them runs the hook again.
List<Uri> _sources(Uri crateDir) => [
  for (final name in ['Cargo.toml', 'Cargo.lock', 'build.rs'])
    if (File.fromUri(crateDir.resolve(name)).existsSync())
      crateDir.resolve(name),
  for (final f in Directory.fromUri(
    crateDir.resolve('src/'),
  ).listSync(recursive: true))
    if (f is File && f.path.endsWith('.rs')) f.uri,
];
