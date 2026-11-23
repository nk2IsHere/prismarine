import 'dart:convert';
import 'dart:io';

import 'package:prismarine_replay/prismarine_replay.dart';
import 'package:test/test.dart';

import 'support/counter_game.dart';

class _Change implements HostChange {
  _Change(this.json);
  final Object json;
  @override
  Object toJson() => json;
}

class _Lines implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  test('the line hash is FNV-1a over UTF-16 units and a line feed', () {
    // The values are from an independent implementation.
    final hashes = [
      for (final l in ['', 'abc', 'é😀'])
        routeHashText(routeLineHash(routeHashSeed, l)),
    ];
    expect(hashes, [
      'af63c74c8601c8dd',
      'fc17b183ee074373',
      'e6cf6d199044c431',
    ]);
  });

  test('the hash text reads back for negative hashes', () {
    for (final h in [0, 1, -1, routeHashSeed, 0x7fffffffffffffff]) {
      expect(parseRouteHash(routeHashText(h)), h);
      expect(routeHashText(h), hasLength(16));
    }
  });

  test(
    'the recorder writes the marker first, dt first and host last',
    () async {
      final sink = _Lines();
      final seen = <String>[];
      final rec = RouteRecorder(counterRoute, {
        'seed': 7,
        't0': 0.0,
      }, sink: sink)..onLine = seen.add;
      rec.addFrame(0.5, {'add': 3});
      rec
        ..hostChange(_Change(['set', 'door', 2]))
        ..hostChange(_Change({'quality': 1}))
        ..addFrame(1 / 60, {
          'add': 0,
          'keys': [32],
        });
      expect(rec.lines, [
        '{"counterRoute":1,"seed":7,"t0":0.0}',
        '{"dt":0.5,"add":3}',
        '{"dt":0.016666666666666666,"add":0,"keys":[32],'
            '"host":[["set","door",2],{"quality":1}]}',
      ]);
      expect(rec.frames, 2);
      expect(sink.lines, rec.lines);
      await sink.close();
      expect(seen, rec.lines.skip(1));
      expect(rec.toJsonLines(), '${rec.lines.join('\n')}\n');
      expect(
        routeHashText(
          RouteRecorder(counterRoute, {'seed': 7, 't0': 0.0}).routeHash,
        ),
        '15933b16888e6bb3',
      );
      final two = recordCounter([3]);
      expect(routeHashText(two.routeHash), '3a5891bb8fb451fe');
    },
  );

  test('a resumed recording keeps the hash chain', () {
    final full = recordCounter([1, 2, 3, 4]);
    final resumed = RouteRecorder.resume(full.lines.take(3).toList());
    resumed
      ..addFrame(0.5, {'add': 3})
      ..addFrame(0.5, {'add': 4});
    expect(resumed.lines, full.lines);
    expect(resumed.routeHash, full.routeHash);
  });

  test('the reader keeps the hash after every line and plays in order', () {
    final rec = recordCounter([5, 6, 7]);
    final r = RouteReader(rec.lines, format: counterRoute);
    expect(r.seed, 7);
    expect(r.t0, 0.0);
    expect(r.frame0, 0);
    expect(r.length, 3);
    expect(r.hashAt(3), rec.routeHash);
    expect(r.next()!['add'], 5);
    expect((r.played, r.remaining), (1, 2));
    r.skipTo(2);
    expect(r.next()!['add'], 7);
    expect(r.next(), isNull);
    expect(() => r.skipTo(4), throwsRangeError);
    final more = recordCounter([5, 6, 7, 8]);
    r.addLine(more.lines.last);
    expect(r.hashAt(4), more.routeHash);
    expect(r.frameAt(3)['add'], 8);
  });

  test('the reader refuses a file without the marker', () {
    expect(
      () => RouteReader(['{"otherRoute":1,"seed":1}'], format: counterRoute),
      throwsFormatException,
    );
    expect(() => RouteReader([], format: counterRoute), throwsFormatException);
  });

  test('prefix lines come from the file as written', () {
    final dir = Directory.systemTemp.createTempSync('route');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rec = recordCounter([1, 2, 3]);
    final path = '${dir.path}/route.jsonl';
    File(path).writeAsStringSync('${rec.lines.join('\n\n')}\n');
    final r = RouteReader(
      RouteReader.splitLines(File(path).readAsStringSync()),
      format: counterRoute,
      path: path,
    );
    expect(r.prefixLines(2), rec.lines.take(3));
    expect(jsonDecode(r.prefixLines(0).single), {
      'counterRoute': 1,
      'seed': 7,
      't0': 0.0,
    });
  });
}
