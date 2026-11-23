/// Builds a package's Rust crate from its Dart build hook (native code is
/// Rust). A hook's `build` callback calls [buildCargoLibrary] with the crate's
/// directory (`crate: 'native/mixer', library: 'mixer', assetName:
/// 'src/mixer/native.dart'`); cargo builds the crate's `cdylib` for the
/// hook's target, and the library ships as a bundled code asset that
/// `@Native` declarations with [assetName] resolve against.
///
/// Cargo is found through `$CARGO`, `PATH`, then `~/.cargo/bin` (rustup's
/// default). Each target needs its Rust standard library installed
/// (`rustup target add <triple>`; macOS app builds are universal, so both
/// `aarch64-apple-darwin` and `x86_64-apple-darwin`). Windows builds use
/// the MSVC toolchain (Visual Studio's C++ build tools); Linux builds need
/// a C compiler and, for the audio library, ALSA's headers
/// (`libasound2-dev`). Crates that build C with CMake (the pad library's
/// SDL) need CMake: found through `$CMAKE`, `PATH` or, on macOS, Homebrew
/// and the CMake app; on Windows Visual Studio's bundled one is enough.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Builds [crate] in release mode. [crate] is the directory that holds
/// `Cargo.toml`, as a path relative to the hook's package or as an absolute
/// URI path. The build adds its dynamic library [library] (the crate's
/// `[lib] name`) as the code asset `package:<package>/<assetName>`.
///
/// [extraSources]: package-relative files or directories outside the crate
/// that its build reads (vendored C its `build.rs` compiles); a change to
/// any reruns the hook, as a change to the crate's own sources does.
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
  // One cargo target dir for every config of this package: cargo keeps the
  // targets apart and rebuilds incrementally.
  final targetDir = input.outputDirectoryShared.resolve('cargo/');
  final cargo = _findCargo();
  // A clean environment: an Xcode build's own variables (SDKROOT, LD,
  // ARCHS, deployment targets…) broke rustc's link; rustup needs HOME (or
  // its own homes) and the linker /usr/bin. Windows keeps what rustc and
  // the cc crate use to find Visual Studio's linker and compiler; Linux
  // keeps the caller's PATH (its C compiler) and pkg-config's paths.
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
    // CMake for crates that build C libraries with it (the `cmake` crate:
    // prismarine_pad builds SDL). It reads `CMAKE`; on macOS the PATH above
    // leaves out Homebrew's; on Windows Visual Studio's own.
    'CMAKE': ?_findCmake(),
    // Its generator: the caller's `CMAKE_GENERATOR`, else Ninja on a Linux
    // box with Ninja and no make (Flutter's Linux builds need Ninja, not
    // make: the player's build image has no make), else on Windows the
    // newest Visual Studio's (the cmake crate finds Visual Studio through
    // devenv.exe, which the Build Tools edition lacks, and then falls back to
    // NMake, which finds no compiler outside a developer prompt).
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
    // The app's minimum for rustc and for the C a crate's build.rs
    // compiles (the cc crate reads it; without it cc targeted the SDK's
    // own version).
    if (code.targetOS == OS.macOS) ...{
      'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}.0',
      // Host-side dylibs (proc-macros: rlsf's rustversion) unstripped too:
      // Xcode 27's strip broke them the same way (see `strip=none` below),
      // and rustc couldn't load them ("can't find crate for `rustversion`").
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
        // No strip pass: Xcode 27's strip (which the release profile's
        // default strip=debuginfo runs) leaves the LINKEDIT string pool
        // 4-byte aligned whenever the indirect symbol table has an odd
        // count, and dyld refuses the dylib ("mis-aligned LINKEDIT string
        // pool"). There is no debug info to strip (debug =
        // false).
        '-C',
        'strip=none',
        // Loaded from the app's frameworks, not from cargo's target dir; room
        // for Flutter to rewrite the install name.
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
  // A per-config copy: assets of different configs never share a file.
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

/// Rust's target triple for a code asset target.
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

/// The bin directory of the CMake bundled with the newest Visual Studio
/// (found with vswhere, as Flutter does). The cmake crate looks for it
/// through `devenv.exe`, which the Build Tools edition doesn't have.
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

/// The CMake generator of the newest Visual Studio (e.g. "Visual Studio 17
/// 2022"), found with vswhere; null without one.
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

/// Whether [exe] is on `PATH`.
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

/// CMake: `$CMAKE`, then `PATH`, then where macOS installs put it
/// (Homebrew on Apple silicon and Intel, the CMake app) or, on Windows,
/// Visual Studio's own (the one Flutter's Windows builds use). Null when
/// none is found (only crates that build C with CMake need it).
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

/// The crate's manifest, lock file, build script and sources: a change to any
/// reruns the hook.
List<Uri> _sources(Uri crateDir) => [
  for (final name in ['Cargo.toml', 'Cargo.lock', 'build.rs'])
    if (File.fromUri(crateDir.resolve(name)).existsSync())
      crateDir.resolve(name),
  for (final f in Directory.fromUri(
    crateDir.resolve('src/'),
  ).listSync(recursive: true))
    if (f is File && f.path.endsWith('.rs')) f.uri,
];
