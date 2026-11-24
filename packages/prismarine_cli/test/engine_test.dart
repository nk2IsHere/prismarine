import 'dart:io';

import 'package:prismarine_cli/src/engine_build.dart';
import 'package:prismarine_cli/src/engine_release.dart';
import 'package:test/test.dart';

void main() {
  test('the subjects of a patch file with several commits', () {
    const text = '''
From 1 Mon Sep 17 00:00:00 2001
Subject: [PATCH 1/2] build: link macOS binaries with Xcode's ld (lld can't
 read the macOS 27 SDK's .tbd files)

diff --git a/x b/x
From 2 Mon Sep 17 00:00:00 2001
Subject: [PATCH 2/2] gpu: a second commit

''';
    expect(patchSubjects(text), [
      "build: link macOS binaries with Xcode's ld (lld can't read the macOS 27 SDK's .tbd files)",
      'gpu: a second commit',
    ]);
  });

  test('a subject outside ASCII is decoded', () {
    const text = '''
Subject: [PATCH] =?UTF-8?q?flutter=5Fgpu=20(x):=20arrays=20?=
 =?UTF-8?q?=E2=80=94=20bit=20256?=

''';
    expect(patchSubjects(text), ['flutter_gpu (x): arrays — bit 256']);
  });

  test('the out folders and gn arguments of each OS and CPU', () {
    expect(outName('macos', 'arm64'), 'host_release_arm64');
    expect(outName('linux', 'arm64'), 'linux_release_arm64');
    expect(outName('windows', 'x64'), 'host_release');
    expect(gnArgs('macos', 'x64'), contains('--mac-cpu=x64'));
    expect(
      gnArgs('linux', 'arm64'),
      containsAll(['--target-os=linux', '--linux-cpu=arm64']),
    );
    expect(
      ninjaTargets('linux', 'arm64'),
      isNot(contains('flutter/impeller/compiler:impellerc')),
    );
    expect(
      ninjaTargets('windows', 'x64'),
      contains('flutter/impeller/compiler:impellerc'),
    );
    expect(targetOf('linux', 'arm64'), ('linux-arm64', 'host_release'));
    expect(targetOf('macos', 'arm64'), ('macos-arm64', null));
  });

  test('gclient leaves out Android and limits the OS', () {
    expect(gclientFile('linux'), contains('target_os = ["linux"]'));
    expect(gclientFile('windows'), contains('target_os = ["win"]'));
    expect(gclientFile('macos'), isNot(contains('target_os')));
    expect(gclientFile('macos'), contains('"download_android_deps": False'));
  });

  test('a release bump writes RELEASE and the engine check', () {
    final tmp = Directory.systemTemp.createTempSync('bump').path;
    File('$tmp/third_party/flutter_engine/RELEASE')
      ..createSync(recursive: true)
      ..writeAsStringSync('engine-deb287481e3c-prismarine1\n');
    final check =
        File('$tmp/packages/prismarine_scene/lib/src/gpu/engine_check.dart')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            "const prismarineEngineRelease = 'engine-deb287481e3c-prismarine1';\n",
          );
    final app = File('$tmp/apps/demo/prismarine.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'engine: engine-deb287481e3c-prismarine1\nflutter: 3.47.7\n',
      );
    final tag = bumpRelease(
      tmp,
      'deb287481e3ce9468f3434937ced4240a70539ca',
      'prismarine2',
    );
    expect(tag, 'engine-deb287481e3c-prismarine2');
    expect(
      File('$tmp/third_party/flutter_engine/RELEASE').readAsStringSync(),
      '$tag\n',
    );
    expect(check.readAsStringSync(), contains("'$tag'"));
    expect(app.readAsStringSync(), 'engine: $tag\nflutter: 3.47.7\n');
    Directory(tmp).deleteSync(recursive: true);
  });
}
