import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_scene/prismarine_scene.dart';

void main() {
  group('FileAssetBundle', () {
    late Directory dir;
    final messages = <String>[];

    setUp(() {
      dir = Directory.systemTemp.createTempSync('prismarine_scene_test');
      messages.clear();
      FileAssetBundle.onMissing = messages.add;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('serves a file by its absolute path', () async {
      final f = File('${dir.path}/a.png')..writeAsBytesSync([1, 2, 3]);
      final data = await FileAssetBundle().load(f.path);
      expect(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), [
        1,
        2,
        3,
      ]);
      expect(messages, isEmpty);
    });

    test(
      'serves the black PNG for a missing file and reports it once',
      () async {
        final path = '${dir.path}/missing.png';
        for (var i = 0; i < 2; i++) {
          final data = await FileAssetBundle().load(path);
          expect(Uint8List.sublistView(data), staticBlackPng);
        }
        expect(messages, ['missing texture $path: drawn transparent black']);
      },
    );
  });

  test('loadPace gives no turn right after one', () async {
    if (loadPace() case final p?) await p;
    expect(loadPace(), isNull);
  });
}
