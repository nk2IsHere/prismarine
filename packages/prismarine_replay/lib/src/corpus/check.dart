part of 'runner.dart';

/// One replay of a check, a chunk of a run or the whole run.
class _Unit {
  _Unit(this.run, this.chunk, this.count);
  final CorpusRun run;
  final Chunk chunk;

  /// The number of chunks of the run. A whole run has 1.
  final int count;

  String _name(String out, String ext) => count == 1
      ? '$out/${run.id}.$ext'
      : '$out/${run.id}.c${chunk.index + 1}.$ext';
  String fp(String out) => _name(out, 'fp.gz');
  String result(String out) => _name(out, 'json');
}

/// The check and the snapshots of a corpus.
extension CorpusCheck on Corpus {
  /// The wall seconds that a chunk may take with every job running,
  /// `--chunk`, 600 by default. 0 replays whole runs.
  double get chunkTarget => double.parse(opt(args, 'chunk') ?? '600');

  double get tail => double.parse(opt(args, 'tail') ?? '15');

  Map? baselineMeta() {
    final f = File('$dir/baseline/BASELINE.json');
    return f.existsSync() ? jsonDecode(f.readAsStringSync()) as Map : null;
  }

  /// Returns the chunks of [r], cut at its baseline's snapshots when it has
  /// them.
  List<Chunk> chunksOf(CorpusRun r, Map? bm) {
    final res = (bm?['result'] as Map?)?.cast<String, Object?>();
    final total =
        ((res?['snapsCost'] ?? res?['cost'] ?? res?['wall']) as num? ?? 0)
            .toDouble();
    final snaps = [
      for (final s in (res?['snaps'] as List?) ?? const [])
        BaselineSnap((s as Map).cast<String, Object?>()),
    ];
    final until = switch (r.json) {
      {'gateUntil': final num g} when args.contains('--gate') => g.toDouble(),
      {'until': final num u} => u.toDouble(),
      _ => null,
    };
    if (snaps.isEmpty ||
        chunkTarget <= 0 ||
        !Directory(snapDir(r)).existsSync()) {
      return [Chunk(0, null, null, total)];
    }
    // The target is the wall time of a chunk with every job running. The
    // plan counts cost, the seconds of a replay alone.
    final cost = chunkTarget / (1 + (jobs - 1) * loadCost);
    return planChunks(snaps, total, target: cost, until: until);
  }

  Future<Map<String, Object?>> _replayUnit(
    List<String> w,
    _Unit u,
    String out,
  ) async {
    final c = u.chunk;
    final res = u.result(out);
    final p = await Process.run(w.first, [
      ...w.skip(1),
      ...replayArgs(u.run),
      '--baseline=$dir/baseline/${u.run.id}.fp.gz',
      '--out=${u.fp(out)}',
      '--result=$res',
      if (c.from case final s?) '--from-snap=${snapDir(u.run)}/${s.file}',
      if (c.toFrames case final f?) '--to-frames=$f',
    ]);
    final j = File(res).existsSync()
        ? (jsonDecode(File(res).readAsStringSync()) as Map)
              .cast<String, Object?>()
        : <String, Object?>{'error': '${p.stdout}${p.stderr}'};
    if (p.exitCode == 3) {
      j['snapshot'] = '${p.stdout}'.trim();
    } else if (p.exitCode > 1) {
      j['error'] = '${p.stdout}${p.stderr}'.trim();
    }
    // A replay that matches keeps no fingerprint. `--keep-fp` keeps every
    // one.
    final fp = File(u.fp(out));
    if (!args.contains('--keep-fp') &&
        ((j['first'] as List?) ?? const []).isEmpty &&
        fp.existsSync()) {
      fp.deleteSync();
    }
    stderr.writeln(
      'check ${u.run.id}'
      '${u.count > 1 ? ' chunk ${c.index + 1}/${u.count}' : ''}: '
      '${'${p.stdout}'.trim().split('\n').last}',
    );
    return j;
  }

  Future<int> check() async {
    await compile();
    final list = runs;
    final meta = baselineMeta();
    if (meta == null) {
      stderr.writeln('check: no baseline in $dir (run baseline first)');
      return 2;
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .substring(0, 15)
        .replaceAll('T', '-');
    final out = Directory(opt(args, 'out') ?? '$dir/checks/$stamp-$commit')
      ..createSync(recursive: true);
    final expect = CorpusExpect.load(opt(args, 'expect'));
    final w = await worker();
    final runMeta = meta['runs'] as Map;
    // The chunks of every run, the longest first. The check then takes
    // about as long as its longest chunk or its total over the jobs.
    final units = [
      for (final r in list)
        for (final cs in [chunksOf(r, runMeta[r.id] as Map?)])
          for (final c in cs) _Unit(r, c, cs.length),
    ];
    final order = [...units.indexed]
      ..sort((a, b) {
        final c = b.$2.chunk.estimate.compareTo(a.$2.chunk.estimate);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final parts = <String, List<Map<String, Object?>?>>{};
    final sw = Stopwatch()..start();
    await pool([for (final (_, u) in order) u], (u) async {
      final j = await _replayUnit(w, u, out.path);
      (parts[u.run.id] ??= List.filled(u.count, null))[u.chunk.index] = j;
    });
    // A run with a chunk whose snapshot this build cannot read replays
    // whole.
    final whole = [
      for (final r in list)
        if (parts[r.id]!.any((j) => j!['snapshot'] != null)) r,
    ];
    if (whole.isNotEmpty) {
      stderr.writeln(
        'check: ${whole.length} runs replay whole (their snapshots don\'t '
        'read here)',
      );
      await pool(whole, (r) async {
        parts[r.id] = [
          await _replayUnit(w, _Unit(r, Chunk(0, null, null, 0), 1), out.path),
        ];
      });
    }
    final results = <String, Map<String, Object?>>{};
    for (final r in list) {
      final ps = parts[r.id]!.cast<Map<String, Object?>>();
      final err = ps.map((j) => j['error']).nonNulls.firstOrNull;
      final j = ps.length == 1
          ? ps.single
          : err != null
          ? <String, Object?>{'error': err}
          : mergeChunks(ps, tail: tail, full: args.contains('--full'));
      final bm = runMeta[r.id] as Map?;
      final note = <String>[];
      if (bm == null) note.add('no baseline for this run');
      if (bm != null && bm['slice'] != sliceId(sliceOf(r))) {
        note.add(
          'its slice changed since the baseline (${bm['slice']} -> '
          '${sliceId(sliceOf(r))}): rebaseline after a reslice',
        );
      }
      for (final (i, c) in ((j['chunks'] as List?) ?? const []).indexed) {
        if ((c as Map)['diverged'] != true || c['from'] == 0) continue;
        note.add(
          'chunk ${i + 1} starts at frame ${c['from']}: '
          '`corpus.dart diff <baseline> ${r.id}.c${i + 1}.fp.gz '
          '--from=${c['from']}`',
        );
      }
      j['notes'] = note;
      results[r.id] = j;
      File(
        '${out.path}/${r.id}.json',
      ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(j));
    }
    // The report has the first divergence per run, then a summary.
    final rep = StringBuffer();
    var unexpected = 0, expected = 0, same = 0, errors = 0;
    for (final r in list) {
      final j = results[r.id]!;
      final first = (j['first'] as List?) ?? const [];
      if (j['error'] != null) {
        errors++;
        rep.writeln('${r.id}: ERROR ${j['error']}');
        continue;
      }
      printFirst(rep, r.id, first);
      for (final n in j['notes'] as List) {
        rep.writeln('  note: $n');
      }
      if (first.isEmpty) {
        same++;
        if (j['baselineLeft'] == true) {
          rep.writeln('  note: the baseline run is longer');
        }
        continue;
      }
      final chans = {for (final d in first) '${(d as Map)['channel']}'};
      final why = expect.explains(r.id, chans);
      if (why != null) {
        expected++;
        rep.writeln('  expected: $why');
      } else {
        unexpected++;
      }
    }
    rep.writeln(
      '\nsummary: ${list.length} runs at $commit against baseline '
      '${meta['commit']}: $same same, $expected expected divergences, '
      '$unexpected unexpected, $errors errors; ${sw.elapsed.inSeconds} s wall, '
      '${units.length} replays, $jobs jobs ($out)',
    );
    File('${out.path}/report.txt').writeAsStringSync('$rep');
    stdout.write(rep);
    return unexpected + errors == 0 ? 0 : 1;
  }

  /// Replays every run against the baseline and writes the snapshots that a
  /// chunked check starts from. A run keeps them only when it matched its
  /// baseline to the end.
  Future<int> snapshots() async {
    await compile();
    final meta = baselineMeta();
    if (meta == null) {
      stderr.writeln('snapshots: no baseline in $dir (run baseline first)');
      return 2;
    }
    final runMeta = meta['runs'] as Map;
    final w = await worker();
    final kept = <String>{};
    final failed = <String>[];
    final sw = Stopwatch()..start();
    final spans = <String, (double, double)>{};
    await pool(longestFirst(runs, runMeta), (r) async {
      final bm = runMeta[r.id] as Map?;
      if (bm == null) {
        failed.add('${r.id} (no baseline)');
        return;
      }
      final tmp = Directory('${snapDir(r)}.new');
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      tmp.createSync(recursive: true);
      final res = '${tmp.path}.json';
      final start = sw.elapsedMilliseconds / 1000;
      final p = await Process.run(w.first, [
        ...w.skip(1),
        ...replayArgs(r),
        '--baseline=$dir/baseline/${r.id}.fp.gz',
        '--out=${tmp.path}.fp.gz',
        '--result=$res',
        '--snaps=${tmp.path}',
        '--snap-frames=$snapFrames',
      ]);
      spans[r.id] = (start, sw.elapsedMilliseconds / 1000);
      final j = File(res).existsSync()
          ? (jsonDecode(File(res).readAsStringSync()) as Map)
                .cast<String, Object?>()
          : const <String, Object?>{};
      for (final f in [File(res), File('${tmp.path}.fp.gz')]) {
        if (f.existsSync()) f.deleteSync();
      }
      final same =
          p.exitCode == 0 &&
          ((j['first'] as List?) ?? const []).isEmpty &&
          j['baselineLeft'] != true;
      if (!same) {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        failed.add(
          '${r.id} (${'${p.stdout}${p.stderr}'.trim().split('\n').last}; '
          'its snapshots would not be the baseline\'s)',
        );
        return;
      }
      final old = Directory(snapDir(r));
      if (old.existsSync()) old.deleteSync(recursive: true);
      tmp.renameSync(old.path);
      kept.add(r.id);
      final result = (bm['result'] as Map)
        ..['snaps'] = j['snaps']
        ..['snapsWall'] = j['wall'];
      bm['snapsCommit'] = commit;
      bm['result'] = result;
      stderr.writeln('snapshots ${r.id}: ${(j['snaps'] as List).length}');
    });
    soloCosts(runMeta, spans, 'snapsCost', only: kept);
    File(
      '$dir/baseline/BASELINE.json',
    ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(meta));
    stdout.writeln(
      'snapshots: ${runs.length} runs at $commit against baseline '
      '${meta['commit']}: ${kept.length} with snapshots'
      '${failed.isEmpty ? '' : ', none for ${failed.join(', ')}'}; '
      '${sw.elapsed.inSeconds} s wall, $jobs jobs',
    );
    return failed.isEmpty ? 0 : 1;
  }
}
