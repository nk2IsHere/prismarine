import 'dart:io';

import 'package:prismarine_cli/prismarine_cli.dart';
import 'package:prismarine_cook/prismarine_cook.dart';
import 'package:test/test.dart';

/// A reader that answers the commands in [answers] by their joined text
/// and fails every other one.
Reader fake(Map<String, String> answers) =>
    (c) => answers[c.join(' ')];

void main() {
  late String tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cli').path);
  tearDown(() => Directory(tmp).deleteSync(recursive: true));

  final toolchain = Toolchain.find(Platform.environment);

  ToolchainChecks checks(String os, Map<String, String> answers) =>
      ToolchainChecks(
        toolchain,
        fake(answers),
        os: os,
        env: {'HOME': tmp, 'USERPROFILE': tmp},
        exists: (_) => false,
      );

  test('every missing tool of macOS is listed with its fix', () {
    final f = checks('macos', {'git --version': 'git version 2.50'}).all(null);
    final problems = {
      for (final x in f)
        if (x.problem) x.what: x.fix,
    };
    expect(problems.keys, containsAll(['Rust', 'Xcode', 'CMake']));
    expect(problems['CMake'], 'brew install cmake');
  });

  test('a missing Rust target gives the rustup line', () {
    final f = checks('macos', {
      'cargo --version': 'cargo 1.88.0',
      'rustup target list --installed': 'aarch64-apple-darwin\n',
    }).rust();
    expect(f.last.problem, true);
    expect(f.last.fix, 'rustup target add x86_64-apple-darwin');
  });

  test('rustup outside the home folder is a problem for build hooks', () {
    final f = ToolchainChecks(
      toolchain,
      fake({'cargo --version': 'cargo 1.88.0'}),
      os: 'linux',
      env: {'HOME': tmp, 'RUSTUP_HOME': '/opt/rustup'},
      exists: (_) => false,
    ).rust();
    expect(f.single.fix, 'ln -s "/opt/rustup" ~/.rustup');
  });

  test('missing Linux packages are one apt line', () {
    final f = checks('linux', {
      'ninja --version': '1.12',
      'pkg-config --version': '1.8',
      'xz --version': 'xz 5',
      'pkg-config --exists gtk+-3.0': '',
    }).linuxPackages();
    expect(f.single.fix, 'sudo apt install clang libasound2-dev liblzma-dev');
  });

  test('an SDK of another engine revision is a problem', () {
    final r = EngineRelease('engine-000000000000-prismarine1', '/x/RELEASE');
    final f = checks('linux', const {}).flutter(r);
    expect(f.problem, toolchain.flutterRoot != null);
  });

  test('the repository of the releases comes from a private config', () {
    File('$tmp/private/config/engine.env')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# releases\nPRISMARINE_ENGINE_REPO="someone/engine"\n',
      );
    final f = File('$tmp/p/third_party/flutter_engine/RELEASE')
      ..createSync(recursive: true)
      ..writeAsStringSync('engine-deb287481e3c-prismarine1');
    final r = EngineRelease.read(f.path);
    expect(releaseRepository(r, const {}), 'someone/engine');
    expect(
      releaseRepository(r, const {'PRISMARINE_ENGINE_REPO': 'a/b'}),
      'a/b',
    );
  });

  test('the built app follows the names of the runners', () {
    File('$tmp/macos/Runner/Configs/AppInfo.xcconfig')
      ..createSync(recursive: true)
      ..writeAsStringSync('PRODUCT_NAME = demo_app\n');
    File('$tmp/linux/CMakeLists.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('set(BINARY_NAME "demo")\n');
    expect(
      builtApp(tmp, 'macos'),
      '$tmp/build/macos/Build/Products/Release/demo_app.app/Contents/MacOS/demo_app',
    );
    expect(builtApp(tmp, 'linux'), endsWith('/release/bundle/demo'));
  });

  test('times have one decimal under a minute', () {
    expect(seconds(const Duration(milliseconds: 2440)), '2.4 s');
    expect(seconds(const Duration(seconds: 185)), '3 min 5 s');
  });

  test('a failed step prints its cause and fix and is thrown again', () async {
    final out = _Lines();
    final ui = Ui(out: out, terminal: false);
    await expectLater(
      ui.step(
        'engine',
        () async => throw Failure('No engine.', fix: 'prismarine engine'),
      ),
      throwsA(isA<Failure>()),
    );
    expect(out.text, contains('engine failed after'));
    expect(out.text, contains('  No engine.\n  fix: prismarine engine'));
    await out.close();
  });
}

class _Lines implements IOSink {
  final b = StringBuffer();
  String get text => '$b';
  @override
  void write(Object? o) => b.write(o);
  @override
  void writeln([Object? o = '']) => b.writeln(o);
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
