import 'dart:io';

import 'package:prismarine_cook/prismarine_cook.dart';
import 'package:test/test.dart';

late String tmp;

String write(String rel, String text) {
  final f = File('$tmp/$rel')..createSync(recursive: true);
  f.writeAsStringSync(text);
  return f.path;
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('cook').path);
  tearDown(() => Directory(tmp).deleteSync(recursive: true));

  group('project', () {
    test('reads shaders and asset steps with defaults', () {
      write('app/pubspec.yaml', 'name: demo\n');
      write('app/prismarine.yaml', '''
shaders:
  main:
    programs: shaders/programs
    out: shaders_generated
assets:
  scene:
    run: [dart, tool/fetch.dart, '--out={out}']
    out: '{data}/demo'
    out-env: DEMO_DATA
    inputs: [tool]
''');
      final p = Project.load('$tmp/app')!;
      expect(p.name, 'demo');
      expect(p.shaders.single.backends, ['metal', 'vulkan']);
      expect(p.shaders.single.shard, 25);
      final a = p.assets.single;
      expect(a.outDir({'DEMO_DATA': '/x'}), '/x');
      expect(a.command('/x'), ['dart', 'tool/fetch.dart', '--out=/x']);
      if (!Platform.isWindows) {
        expect(a.outDir({'HOME': '/h'}), '/h/.prismarine/demo');
      }
    });

    test('an unknown key fails with the keys of the section', () {
      write('app/prismarine.yaml', 'shaders:\n  a:\n    program: x\n');
      expect(
        () => Project.load('$tmp/app'),
        throwsA(
          isA<ProjectError>().having(
            (e) => e.message,
            'message',
            contains('programs'),
          ),
        ),
      );
    });

    test('find goes up to the folder with the file', () {
      write('app/prismarine.yaml', '');
      Directory('$tmp/app/lib/src').createSync(recursive: true);
      expect(
        Project.find('$tmp/app/lib/src'),
        Directory('$tmp/app').absolute.path,
      );
    });
  });

  group('stamps', () {
    test('the key changes with a file and not with a second read', () {
      write('tree/a.txt', 'one');
      final k1 = hashInputs(['x'], trees: ['$tmp/tree']);
      expect(hashInputs(['x'], trees: ['$tmp/tree']), k1);
      write('tree/a.txt', 'two');
      expect(hashInputs(['x'], trees: ['$tmp/tree']), isNot(k1));
      write('tree/b.txt', '');
      expect(hashInputs(['x'], trees: ['$tmp/tree']), isNot(k1));
    });

    test('a stamp keeps its time when written again with the same key', () {
      final s = Stamp('$tmp/out/cook.json')..write('k', {'shaders': 3});
      expect(s.key, 'k');
      expect(s.fields['shaders'], 3);
      expect(File(s.path).lastModifiedSync().year, 2000);
      s.write('k', {'shaders': 3});
      expect(File(s.path).lastModifiedSync().year, 2000);
    });

    test(
      'an asset step runs once, then again after an input changed',
      () async {
        write('app/prismarine.yaml', '''
assets:
  scene:
    run: [make]
    out: $tmp/data
    inputs: [tool]
''');
        write('app/tool/fetch.dart', 'one');
        final p = Project.load('$tmp/app')!;
        var runs = 0;
        Future<int> run(List<String> c, String d) async {
          runs++;
          return 0;
        }

        expect((await cookAsset(p, p.assets.single, run: run)).current, false);
        expect((await cookAsset(p, p.assets.single, run: run)).current, true);
        write('app/tool/fetch.dart', 'two');
        expect((await cookAsset(p, p.assets.single, run: run)).current, false);
        expect(runs, 2);
      },
    );

    test('an output with its marker files and no stamp is taken', () async {
      write('app/prismarine.yaml', '''
assets:
  scene:
    run: [make]
    out: $tmp/data
    exists: [prepared/scene.gltf]
''');
      write('data/prepared/scene.gltf', '{}');
      final p = Project.load('$tmp/app')!;
      final c = await cookAsset(
        p,
        p.assets.single,
        run: (c, d) async => throw StateError('ran'),
      );
      expect(c.adopted, true);
    });

    test('a failed step leaves no stamp', () async {
      write(
        'app/prismarine.yaml',
        'assets:\n  s:\n    run: [x]\n    out: $tmp/data\n',
      );
      final p = Project.load('$tmp/app')!;
      await expectLater(
        cookAsset(p, p.assets.single, run: (c, d) async => 3),
        throwsA(isA<AssetStepError>()),
      );
      expect(File('$tmp/data/cook-s.json').existsSync(), false);
    });
  });

  group('engine', () {
    const tag = 'engine-deb287481e3c-prismarine1';

    EngineRelease release() => EngineRelease.read(
      write('p/third_party/flutter_engine/RELEASE', '$tag\n'),
    );

    test('the release has its revision and name', () {
      final r = release();
      expect(r.revision, 'deb287481e3c');
      expect(r.name, 'prismarine1');
      expect(
        Directory(r.checkout).absolute.path,
        Directory('$tmp/p').absolute.path,
      );
    });

    test('a fetched engine of the release comes first', () {
      write(
        'engine/linux-x64/prismarine-engine.txt',
        'release=$tag\nout=host_release\nengine_revision=abc\n',
      );
      final s = findEngine('$tmp/engine', 'linux-x64', release());
      expect(s.engine!.fetched, true);
      expect(
        s.engine!.flutterArgs.first,
        '--local-engine-src-path=$tmp/engine/linux-x64/src',
      );
      expect(s.engine!.revision, 'abc');
    });

    test('a fetched engine of another release is reported, not used', () {
      write(
        'engine/linux-x64/prismarine-engine.txt',
        'release=engine-deb287481e3c-prismarine0\n',
      );
      final s = findEngine('$tmp/engine', 'linux-x64', release());
      expect(s.engine, isNull);
      expect(s.otherRelease, 'engine-deb287481e3c-prismarine0');
    });

    test('a built engine with the prismarine exports is taken', () {
      write(
        'engine/flutter/engine/src/out/host_release/libflutter_linux_gtk.so',
        '${'x' * 100}InternalFlutterGpu_PrismarineFeatures${'y' * 10}',
      );
      final s = findEngine('$tmp/engine', 'linux-x64', release());
      expect(s.engine!.fetched, false);
      expect(s.engine!.out, 'host_release');
    });

    test('a built engine without them is not', () {
      write(
        'engine/flutter/engine/src/out/host_release/libflutter_linux_gtk.so',
        'InternalFlutterGpu_OtherFeatures',
      );
      expect(findEngine('$tmp/engine', 'linux-x64', release()).engine, isNull);
    });

    test('the search finds text across the edge of a read', () {
      final f = File('$tmp/big')
        ..writeAsBytesSync([
          ...List.filled((1 << 22) - 5, 0),
          ...'needle-text'.codeUnits,
        ]);
      expect(fileContains(f.path, 'needle-text'), true);
      expect(fileContains(f.path, 'needle-texts'), false);
    });

    test('the hook takes the choice of the last command', () {
      final ic = write('ic/impellerc', '');
      EngineChoice(ic, tag).writeIn('$tmp/app');
      expect(hookImpellerc('$tmp/app', const {}), ic);
    });

    test('the hook without a choice or package config gives the fix', () {
      expect(
        () => hookImpellerc('$tmp/app', const {'HOME': '/nowhere'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'm',
            contains('prismarine build'),
          ),
        ),
      );
    });

    test('the release of an app is beside its flutter_gpu', () {
      release();
      Directory('$tmp/p/third_party/flutter_gpu').createSync(recursive: true);
      write('app/.dart_tool/package_config.json', '''
{"configVersion": 2, "packages": [
 {"name": "flutter_gpu", "rootUri": "../../p/third_party/flutter_gpu", "packageUri": "lib/"}
]}''');
      expect(
        File(releaseFileOfApp('$tmp/app')!).readAsStringSync().trim(),
        tag,
      );
    });
  });

  test('every target has an out folder', () {
    expect(builtOutDir('macos-arm64'), 'host_release_arm64');
    expect(builtOutDir('linux-arm64'), 'linux_release_arm64');
    expect(builtOutDir('windows-x64'), 'host_release');
    expect(hostTarget(), isNotNull);
  });
}
