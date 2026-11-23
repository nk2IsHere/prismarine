import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'chunks.dart';
import 'divergence.dart';
import 'io.dart';

part 'check.dart';

/// One run of a corpus list with its entry in the list.
class CorpusRun {
  CorpusRun(this.json) : id = json['id']! as String;
  final Map<String, Object?> json;
  final String id;
}

/// The corpus runner. A game extends it with the data, the arguments and
/// the recording of its runs. The commands are `record`, `baseline`,
/// `rebaseline`, `check` and `snapshots`. The workers run [entry], the
/// game's corpus program, with `replay` and the arguments of one replay.
abstract class Corpus {
  /// [dir] holds the runs, the baseline and the checks. [entry] is the
  /// game's corpus program. The list of runs is `--list`, else `corpus.json`
  /// beside [entry].
  Corpus(this.args, {required this.dir, required this.entry})
    : jobs = int.parse(
        opt(args, 'jobs') ?? '${math.max(1, Platform.numberOfProcessors ~/ 2)}',
      );
  final List<String> args;
  final String dir, entry;
  final int jobs;
  String? exe;

  /// The folder of [entry].
  String get entryDir => File(entry).parent.path;

  /// Returns the data folder, such as a slice, that run [r] plays.
  String sliceOf(CorpusRun r);

  /// Returns the identity of the data folder [slice]. A check notes a run
  /// whose identity changed since its baseline.
  String sliceId(String slice);

  /// Returns the arguments of a replay of [r] that follow its route.
  List<String> runArgs(CorpusRun r);

  /// Returns true for an option of the command line that every replay gets.
  bool passes(String arg) => false;

  /// Runs once before `record` records its runs.
  Future<void> beforeRecord() async {}

  /// Records the route of [r] into [dir] at [routeOf]. Adds its facts to
  /// [meta]. Returns false when the recording failed.
  Future<bool> recordRun(CorpusRun r, Directory dir, Map<String, Object?> meta);

  /// The run list.
  late final Map<String, Object?> listJson =
      (jsonDecode(
                File(
                  opt(args, 'list') ?? '$entryDir/corpus.json',
                ).readAsStringSync(),
              )
              as Map)
          .cast<String, Object?>();

  /// The runs of the list. `--gate` leaves out the runs marked `nightly`.
  /// `--only=<ids>` keeps the runs that match one of its globs.
  List<CorpusRun> get runs {
    final all = [
      for (final r in listJson['runs']! as List)
        CorpusRun((r as Map).cast<String, Object?>()),
    ];
    if (args.contains('--gate')) {
      all.removeWhere((r) => r.json['nightly'] == true);
    }
    final only = opt(args, 'only')?.split(',');
    if (only == null) return all;
    return [
      for (final r in all)
        if (only.any((o) => glob(o, r.id))) r,
    ];
  }

  String _git(List<String> a) {
    final r = Process.runSync('git', a, workingDirectory: entryDir);
    return '${r.stdout}'.trim();
  }

  /// The commit of this tree, or `CORPUS_COMMIT` in a tree that is no git
  /// checkout, such as a `git archive` of one.
  String get commit {
    final c = _git(['rev-parse', '--short=8', 'HEAD']);
    if (c.isNotEmpty && !c.contains(' ')) return c;
    return Platform.environment['CORPUS_COMMIT'] ?? 'unknown';
  }

  /// The route file of [r].
  String routeOf(CorpusRun r) => '$dir/runs/${r.id}/route.jsonl.gz';

  /// The command line that runs a worker.
  Future<List<String>> worker() async {
    if (exe != null) return [exe!];
    return ['dart', 'run', entry];
  }

  /// Compiles [entry] once with its native assets. `--jit` runs it with
  /// `dart run` and `--exe=<file>` runs a compiled one.
  Future<void> compile() async {
    if (args.contains('--jit')) return;
    if (opt(args, 'exe') case final String e) {
      exe = e;
      return;
    }
    final name = File(entry).uri.pathSegments.last.replaceAll('.dart', '');
    final out = '$dir/bin/$name-$commit-$pid';
    stderr.writeln('compiling the corpus tool ($out)');
    final r = await Process.run('dart', [
      'build',
      'cli',
      '-t',
      entry,
      '-o',
      out,
    ], workingDirectory: entryDir);
    final bin = '$out/bundle/bin/$name';
    if (r.exitCode != 0 || !File(bin).existsSync()) {
      stderr.writeln('${r.stdout}${r.stderr}');
      exit(2);
    }
    exe = bin;
  }

  /// Runs [f] on each of [items] with at most [jobs] at a time, in order.
  Future<void> pool<T>(List<T> items, Future<void> Function(T) f) async {
    final queue = [...items];
    Future<void> w() async {
      while (queue.isNotEmpty) {
        await f(queue.removeAt(0));
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(jobs, items.length); i++) w(),
    ]);
  }

  /// Runs the command [cmd]. Returns the exit code.
  Future<int> run(String cmd) async {
    switch (cmd) {
      case 'record':
        return record();
      case 'baseline':
        return baseline(runs);
      case 'rebaseline':
        if (opt(args, 'only') == null && !args.contains('--all')) {
          stderr.writeln('rebaseline: --only=<ids> or --all');
          return 2;
        }
        return baseline(runs, merge: true);
      case 'check':
        return check();
      case 'snapshots':
        return snapshots();
    }
    return 2;
  }

  /// Records the route of every run into `<dir>/runs/<id>/`.
  Future<int> record() async {
    final list = runs;
    var failed = 0;
    Directory(dir).createSync(recursive: true);
    await beforeRecord();
    final sw = Stopwatch()..start();
    await pool(list, (r) async {
      final rd = Directory('$dir/runs/${r.id}')..createSync(recursive: true);
      final meta = <String, Object?>{
        'id': r.id,
        'recordedOn': commit,
        'made': DateTime.now().toIso8601String(),
      };
      if (!await recordRun(r, rd, meta)) failed++;
      File(
        '${rd.path}/meta.json',
      ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(meta));
    });
    stderr.writeln(
      'record: ${list.length} runs, $failed failed, ${sw.elapsed.inSeconds} s',
    );
    return failed == 0 ? 0 : 1;
  }

  /// Returns the arguments of a worker's replay of [r]. `--gate` limits a
  /// run to its `gateUntil`, else its `until` limits it.
  List<String> replayArgs(CorpusRun r) => [
    'replay',
    routeOf(r),
    ...runArgs(r),
    if (args.contains('--gate') && r.json['gateUntil'] != null)
      '--until=${r.json['gateUntil']}'
    else if (r.json['until'] case final u?)
      '--until=$u',
    for (final a in args)
      if (a.startsWith('--tail=') || a == '--full' || passes(a)) a,
  ];

  /// The folder of the baseline's snapshots of [r].
  String snapDir(CorpusRun r) => '$dir/baseline/snaps/${r.id}';

  /// Sets the cost of each run and of its snapshots in [runMeta] from the
  /// pool's [spans] with [SoloCosts]. The run's result gets [key] and each
  /// snapshot gets `cost`.
  void soloCosts(
    Map runMeta,
    Map<String, (double, double)> spans,
    String key, {
    Set<String>? only,
  }) {
    final costs = SoloCosts(spans.values.toList());
    for (final MapEntry(key: id, value: (a, b)) in spans.entries) {
      if (only != null && !only.contains(id)) continue;
      final result = (runMeta[id] as Map?)?['result'] as Map?;
      if (result == null) continue;
      result[key] = costs.of(a, b);
      for (final s in (result['snaps'] as List?) ?? const []) {
        (s as Map)['cost'] = costs.of(a, a + (s['wall'] as num).toDouble());
      }
    }
  }

  /// The route frames between two snapshots of a baseline replay,
  /// `--snap-frames`, 15000 by default.
  int get snapFrames => int.parse(opt(args, 'snap-frames') ?? '15000');

  /// Returns [list] with the runs that the baseline replayed longest first
  /// and the rest after them in list order.
  List<CorpusRun> longestFirst(List<CorpusRun> list, Map runMeta) {
    double wall(CorpusRun r) =>
        ((((runMeta[r.id] as Map?)?['result'] as Map?)?['wall'] as num?) ?? 0)
            .toDouble();
    final order = [...list.indexed]
      ..sort((a, b) {
        final c = wall(b.$2).compareTo(wall(a.$2));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final (_, r) in order) r];
  }

  /// Replays every run of [list] and writes its fingerprint, its result and
  /// its snapshots into `<dir>/baseline/`. [merge] keeps the entries of the
  /// other runs in `BASELINE.json`.
  Future<int> baseline(List<CorpusRun> list, {bool merge = false}) async {
    await compile();
    final bd = Directory('$dir/baseline')..createSync(recursive: true);
    final metaFile = File('${bd.path}/BASELINE.json');
    if (opt(args, 'only') != null) merge = true;
    final meta = merge && metaFile.existsSync()
        ? (jsonDecode(metaFile.readAsStringSync()) as Map)
              .cast<String, Object?>()
        : <String, Object?>{'runs': <String, Object?>{}};
    final runMeta = (meta['runs'] as Map).cast<String, Object?>();
    final w = await worker();
    var failed = 0;
    final sw = Stopwatch()..start();
    final spans = <String, (double, double)>{};
    await pool(longestFirst(list, runMeta), (r) async {
      if (!File(routeOf(r)).existsSync()) {
        stderr.writeln('baseline ${r.id}: no route (run record first)');
        failed++;
        return;
      }
      final out = '${bd.path}/${r.id}.fp.gz';
      final res = '${bd.path}/${r.id}.json';
      final snaps = Directory(snapDir(r));
      if (snaps.existsSync()) snaps.deleteSync(recursive: true);
      final start = sw.elapsedMilliseconds / 1000;
      final p = await Process.run(w.first, [
        ...w.skip(1),
        ...replayArgs(r),
        '--out=$out',
        '--result=$res',
        '--snaps=${snaps.path}',
        '--snap-frames=$snapFrames',
      ]);
      spans[r.id] = (start, sw.elapsedMilliseconds / 1000);
      if (p.exitCode != 0) {
        failed++;
        stderr.writeln('baseline ${r.id}: FAILED\n${p.stdout}${p.stderr}');
        return;
      }
      runMeta[r.id] = {
        'commit': commit,
        'slice': sliceId(sliceOf(r)),
        'result': jsonDecode(File(res).readAsStringSync()),
      };
      stderr.writeln('baseline ${r.id}: ${'${p.stdout}'.trim()}');
    });
    soloCosts(runMeta, spans, 'cost');
    meta['commit'] = commit;
    meta['made'] = DateTime.now().toIso8601String();
    metaFile.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(meta));
    stderr.writeln(
      'baseline: ${list.length} runs, $failed failed, ${sw.elapsed.inSeconds} s wall',
    );
    return failed == 0 ? 0 : 1;
  }
}
