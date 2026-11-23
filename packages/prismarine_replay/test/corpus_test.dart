import 'dart:convert';
import 'dart:io';

import 'package:prismarine_replay/corpus.dart';
import 'package:test/test.dart';

BaselineSnap _snap(int frames, double time, double cost) => BaselineSnap({
  'file': '$frames.snap',
  'frames': frames,
  'frame': frames,
  'time': time,
  'wall': cost,
});

class _Corpus extends Corpus {
  _Corpus(super.args, {required super.dir, required super.entry});
  @override
  String sliceOf(CorpusRun r) => '$dir/data/${r.id}';
  @override
  String sliceId(String slice) => 'id';
  @override
  List<String> runArgs(CorpusRun r) => ['--data=${sliceOf(r)}'];
  @override
  bool passes(String arg) => arg.startsWith('--tol=');
  @override
  Future<bool> recordRun(
    CorpusRun r,
    Directory dir,
    Map<String, Object?> meta,
  ) async {
    meta['recorded'] = true;
    return r.id != 'b';
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('corpus'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a run is cut at its snapshots within the target cost', () {
    final snaps = [_snap(100, 10, 4), _snap(200, 20, 8), _snap(300, 30, 12)];
    final chunks = planChunks(snaps, 16, target: 5);
    expect([for (final c in chunks) c.from?.frames], [null, 100, 200, 300]);
    expect([for (final c in chunks) c.toFrames], [100, 200, 300, null]);
    expect([for (final c in chunks) c.estimate], [4, 4, 4, 4]);
    expect(planChunks(snaps, 16, target: 9).length, 2);
    expect(planChunks(const [], 16, target: 5).single.estimate, 16);
    final until = planChunks(snaps, 16, target: 5, until: 15);
    expect([for (final c in until) c.from?.frames], [null, 100]);
    expect(until.last.estimate, 2);
  });

  test('chunk results merge into the result of the whole run', () {
    final merged = mergeChunks(
      [
        {
          'route': 'r',
          'frames': 10,
          'wall': 1.5,
          'first': [
            {'channel': 'camera', 'frame': 8, 't': 4.0},
          ],
        },
        {
          'route': 'r',
          'frames': 5,
          'wall': 1.0,
          'fromFrame': 10,
          'end': 7.5,
          'baselineLeft': false,
          'first': [
            {'channel': 'camera', 'frame': 12, 't': 6.0},
            {'channel': 'audio', 'frame': 14, 't': 30.0},
          ],
        },
      ],
      tail: 15,
      full: false,
    );
    expect(merged['frames'], 15);
    expect(merged['wall'], 2.5);
    expect(merged['first'], [
      {'channel': 'camera', 'frame': 8, 't': 4.0},
    ]);
    expect((merged['chunks']! as List).map((c) => (c as Map)['from']), [0, 10]);
  });

  test('solo costs divide the time by the jobs beside each one', () {
    final costs = SoloCosts([(0, 10), (0, 5)]);
    expect(costs.of(5, 10), 5);
    expect(costs.of(0, 5), closeTo(5 / (1 + loadCost), 1e-9));
  });

  test('the expected note matches ids by glob and channels', () {
    final f = File('${dir.path}/expect.txt')
      ..writeAsStringSync('ep*-A camera,agents # moved\nother\n# none\n');
    final e = CorpusExpect.load(f.path);
    expect(e.explains('ep1-A', {'camera'}), 'moved');
    expect(e.explains('ep1-A', {'audio'}), isNull);
    expect(e.explains('other', {'audio'}), '(listed)');
    expect(CorpusExpect.load(null).explains('x', {}), isNull);
    expect(glob('a*c', 'abbc'), isTrue);
    expect(glob('a.c', 'abc'), isFalse);
    expect(opt(['--only=a,b', '--x'], 'only'), 'a,b');
  });

  test('the report lists the first divergences earliest first', () {
    final out = StringBuffer();
    printFirst(out, 'run', [
      Divergence('audio', 20, 2, 'Hall', 'late'),
      {
        'channel': 'camera',
        'frame': 10,
        't': 1.0,
        'scene': 'Hall',
        'detail': 'moved',
      },
    ]);
    printFirst(out, 'other', const []);
    expect(
      '$out',
      'run: DIVERGES at t 1.000 (frame 10) in Hall\n'
          '  camera  t 1.000 Hall: moved\n'
          '  audio   t 2.000 Hall: late\n'
          'other: same\n',
    );
  });

  test('gzip lines read back one at a time', () {
    final path = '${dir.path}/lines.gz';
    final w = GzWriter(path);
    for (var i = 0; i < 3; i++) {
      w.writeln('line $i');
    }
    w.close();
    final r = LineReader(path);
    expect(r.peek(), 'line 0');
    expect(
      [r.next(), r.next(), r.next(), r.next()],
      ['line 0', 'line 1', 'line 2', null],
    );
    expect(
      utf8.decode(gzip.decode(File(path).readAsBytesSync())),
      'line 0\nline 1\nline 2\n',
    );
  });

  test('the runner filters runs and builds the replay arguments', () async {
    final list = File('${dir.path}/corpus.json')
      ..writeAsStringSync(
        jsonEncode({
          'runs': [
            {'id': 'a', 'until': 50},
            {'id': 'b', 'nightly': true, 'gateUntil': 20},
            {'id': 'c', 'gateUntil': 30},
          ],
        }),
      );
    Corpus make(List<String> args) =>
        _Corpus(args, dir: dir.path, entry: '${dir.path}/corpus.dart');
    expect(make([]).runs.map((r) => r.id), ['a', 'b', 'c']);
    expect(make(['--gate']).runs.map((r) => r.id), ['a', 'c']);
    expect(make(['--only=b,c']).runs.map((r) => r.id), ['b', 'c']);
    final gate = make(['--gate', '--tol=1', '--full', '--tail=5', '--x']);
    expect(gate.replayArgs(gate.runs.last), [
      'replay',
      '${dir.path}/runs/c/route.jsonl.gz',
      '--data=${dir.path}/data/c',
      '--until=30',
      '--tol=1',
      '--full',
      '--tail=5',
    ]);
    expect(make([]).replayArgs(make([]).runs.first)[3], '--until=50');
    expect(list.existsSync(), isTrue);
    final rec = make(['--jobs=2']);
    expect(await rec.run('record'), 1);
    final meta = jsonDecode(
      File('${dir.path}/runs/a/meta.json').readAsStringSync(),
    );
    expect(meta['recorded'], isTrue);
    expect(meta['id'], 'a');
    expect(await make([]).run('rebaseline'), 2);
  });
}
