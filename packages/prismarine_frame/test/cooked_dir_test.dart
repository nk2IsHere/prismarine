import 'dart:io';

import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:test/test.dart';

void main() {
  test('the pulled directory comes from the environment first', () {
    final none = Directory.systemTemp.createTempSync('pulled').path;
    addTearDown(() => Directory(none).deleteSync(recursive: true));
    expect(pulledDir(none, environment: {}), isNull);
    expect(pulledDir(none, environment: {'PRISMARINE_PULLED': '/a'}), '/a');
    expect(pulledDir(none, environment: {'MCSM_PULLED': '/b'}), '/b');
    expect(
      pulledDir(
        none,
        environment: {'PRISMARINE_PULLED': 'off', 'MCSM_PULLED': '/b'},
      ),
      isNull,
    );
  });

  test('a cooked directory of the current version is found', () {
    final content = Directory.systemTemp.createTempSync('pulled').path;
    addTearDown(() => Directory(content).deleteSync(recursive: true));
    Directory('$content/cooked/shaders/bundle').createSync(recursive: true);
    expect(pulledDir(content, environment: {}), isNull);
    File('$content/cooked/scene/cooked.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"version": $cookVersion}');
    expect(pulledDir(content, environment: {}), '$content/cooked');
    File(
      '$content/cooked/scene/cooked.json',
    ).writeAsStringSync('{"version": ${cookVersion - 1}}');
    expect(pulledDir(content, environment: {}), isNull);
  });
}
