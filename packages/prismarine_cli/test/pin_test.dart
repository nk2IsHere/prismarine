import 'dart:io';

import 'package:prismarine_cli/src/pin.dart';
import 'package:test/test.dart';

void main() {
  late String root;
  const url = 'https://prismarine.invalid/prismarine.git';
  const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  String dep(String name, String ref) =>
      '  $name:\n    git:\n      url: $url\n      path: packages/$name\n      ref: $ref\n';

  setUp(() {
    root = Directory.systemTemp
        .createTempSync('pin')
        .resolveSymbolicLinksSync();
    File('$root/pubspec.yaml').writeAsStringSync(
      'name: w\nworkspace:\n  - lib_a\ndependencies:\n${dep('prismarine_kept', a)}',
    );
    File('$root/lib_a/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'name: a\nresolution: workspace\ndependencies:\n${dep('prismarine_math', a)}',
      );
    File('$root/app/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'name: app\ndependencies:\n${dep('prismarine_scene', a)}',
      );
    Process.runSync('git', ['init', '-q', root]);
    Process.runSync('git', ['-C', root, 'add', '.']);
  });
  tearDown(() => Directory(root).deleteSync(recursive: true));

  test('the URL, the pin and the roots come from the tracked pubspecs', () {
    final t = PinTree.find('$root/lib_a');
    expect(t.url, url);
    expect(t.sha, a);
    expect(
      t.pubspecs,
      unorderedEquals([
        'pubspec.yaml',
        'lib_a/pubspec.yaml',
        'app/pubspec.yaml',
      ]),
    );
    expect(t.roots, unorderedEquals(['.', 'app']));
  });

  test('a new pin rewrites every pubspec', () {
    final t = PinTree.find(root);
    expect(t.setPin(b), hasLength(3));
    expect(PinTree.find(root).sha, b);
  });

  test('two pins are a failure', () {
    File('$root/app/pubspec.yaml').writeAsStringSync(
      'name: app\ndependencies:\n${dep('prismarine_scene', b)}',
    );
    expect(() => PinTree.find(root).sha, throwsA(isA<Exception>()));
  });

  test('link overrides each root with the packages of a checkout', () {
    final c = '$root/checkout';
    for (final p in ['prismarine_kept', 'prismarine_math']) {
      File('$c/packages/$p/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: $p\n');
    }
    final links = PinTree.find(root).links(c);
    expect(
      links.keys,
      unorderedEquals([
        './pubspec_overrides.yaml',
        'app/pubspec_overrides.yaml',
      ]),
    );
    expect(
      links['app/pubspec_overrides.yaml'],
      contains('path: $c/packages/prismarine_math'),
    );
  });
}
