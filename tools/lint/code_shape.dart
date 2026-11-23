// code_shape checks file size, history in comments and the rule sets of the
// repository and ratchets the hits against its baseline. Usage --help.
import 'dart:convert';
import 'dart:io';

import 'src/config.dart';
import 'src/lexer.dart';
import 'src/rule_sets.dart';
import 'src/rules.dart';
import 'src/scope.dart';

const usage = r'''
code_shape checks file size, history in comments and the rule sets of the
repository and ratchets the hits against the baseline in
tools/lint/config.yaml.

  dart tools/lint/code_shape.dart [options] [<path>...]

Checks (scope: tracked code under the config's code roots; not
third_party/, runner scaffolding, golden files or generated files):
  size          files over 1,000 lines (error) and over 500 (warning)
  history       dates, run ids, agent/branch names, hashes, narrative,
                plan/report/memory/research pointers, "the user"
  long-comment  comment blocks over 12 lines (a file header: 20)
  function      functions over 150 lines (warning only)
  exe-address   addresses of shipped binaries in comments or strings, when
                code_shape.rule_sets in the config has this set
  name-words    words that identifiers and paths must not contain, when
                code_shape.rule_sets in the config has this set, once per
                key that starts with name-words
The rules and their heuristics are in src/rules.dart and src/rule_sets.dart.
The lint's own files quote the patterns, so they get the size check only.

The ratchet: files over 1,000 lines may not grow and no new one may
appear; history, long-comment and rule-set hits are counted per package
and no package's count may grow (per package, so moving code between files
of a package doesn't trip it). Once a package's counts reach zero its
entry goes and any new hit fails.

Options:
  --list[=<check>,...]  print every hit (default: errors and ratchet result)
  --summary             counts per package
  --update-baseline     rewrite the baseline when nothing grew; with
                        --allow-moves, counts may move between packages
                        as long as no check's tree-wide total grows; with
                        --force, whatever the counts (only for a commit
                        same_code proves layout-only: formatting adds lines)
  --json=<file>         write every hit as JSON
With paths, only the hits in those files are listed (no ratchet).

Exit codes: 0 clean against the baseline, 1 a violation grew or appeared,
2 usage error.
''';

late final String baselinePath;

/// The ratcheted checks of the generic rules and the rule sets, sorted.
late final List<String> ratcheted;

class FileReport {
  FileReport(this.path, this.package, this.lines);
  final String path;
  final String package;
  final int lines;
  final hits = <Hit>[];
  final functions = <FunctionSpan>[];
}

void main(List<String> args) {
  final opts = args.where((a) => a.startsWith('--')).toList();
  final paths = args.where((a) => !a.startsWith('--')).toList();
  String? opt(String name) {
    for (final o in opts) {
      if (o == '--$name') return '';
      if (o.startsWith('--$name=')) return o.substring(name.length + 3);
    }
    return null;
  }

  const known = [
    'help',
    'list',
    'summary',
    'update-baseline',
    'allow-moves',
    'force',
    'json',
  ];
  for (final o in opts) {
    final name = o.substring(2).split('=').first;
    if (!known.contains(name)) {
      stderr.writeln('code_shape: unknown option $o');
      exit(2);
    }
  }

  if (opt('help') != null) {
    stdout.write(usage);
    return;
  }
  final root = repoRoot();
  final (sets, history) = _rules(root);
  final pkgDirs = packageDirs(root);
  var files = trackedCodeFiles(root);
  if (paths.isNotEmpty) {
    files = files.where((f) => paths.any((p) => f.startsWith(p))).toList();
  }
  final reports = <FileReport>[];
  // Hash-shaped words in comments, resolved against git in one call below.
  final hashes = <(FileReport, int, String, String)>[];
  for (final path in files) {
    final text = File('$root/$path').readAsStringSync();
    if (isGenerated(text)) continue;
    final lang = langOf(path)!;
    final toks = lex(text, lang);
    final r = FileReport(path, packageOf(path, pkgDirs), lineCount(text));
    if (!commentCheckExempt.any(path.startsWith)) {
      r.hits
        ..addAll(commentHits(toks, lang, history, sets))
        ..addAll(longCommentHits(toks));
      for (final s in sets) {
        r.hits.addAll(s.codeHits(path, toks));
      }
    }
    // A test file's main only registers its tests.
    final isTest =
        path.contains('/test/') || path.contains('/integration_test/');
    r.functions.addAll(
      longFunctions(toks, lang).where((f) => !(isTest && f.name == 'main')),
    );
    for (final t in toks.where(
      (t) =>
          t.kind == TokKind.comment && !commentCheckExempt.any(path.startsWith),
    )) {
      final lines = t.text.split('\n');
      for (var k = 0; k < lines.length; k++) {
        for (final h in hashCandidates(lines[k])) {
          hashes.add((r, t.line + k, lines[k].trim(), h));
        }
      }
    }
    reports.add(r);
  }
  if (sets.any((s) => s.checksAllPaths)) {
    for (final path in trackedOtherFiles(root)) {
      if (paths.isNotEmpty && !paths.any(path.startsWith)) continue;
      final r = FileReport(path, packageOf(path, pkgDirs), 0);
      for (final s in sets) {
        r.hits.addAll(s.pathHits(path));
      }
      if (r.hits.isNotEmpty) reports.add(r);
    }
  }
  final commits = knownCommits(root, {for (final h in hashes) h.$4});
  for (final (r, line, text, h) in hashes) {
    if (!commits.contains(h)) continue;
    if (r.hits.any((x) => x.check == 'history' && x.line == line)) continue;
    r.hits.add(Hit('history', 'hash', line, text));
  }
  for (final r in reports) {
    r.hits.sort((a, b) => a.line.compareTo(b.line));
  }

  final list = opt('list');
  if (list != null) _list(reports, list.isEmpty ? null : list.split(','));
  if (opt('json') case final j? when j.isNotEmpty) _writeJson(reports, j);
  final now = _counts(reports);
  if (opt('summary') != null) _summary(reports, now);

  final soft = reports.where((r) => r.lines > softLimit).length;
  final hard = reports.where((r) => r.lines > hardLimit).length;
  final funcs = reports.fold(0, (n, r) => n + r.functions.length);
  stdout.writeln(
    'code_shape: ${reports.length} files; $hard over $hardLimit '
    'lines, $soft over $softLimit; ${now.totals.entries.map((e) => '${e.value} ${e.key}').join(', ')}; '
    '$funcs functions over $functionLimit lines',
  );
  if (paths.isNotEmpty) return;

  final baseFile = File('$root/$baselinePath');
  final base = baseFile.existsSync()
      ? Counts.fromJson(jsonDecode(baseFile.readAsStringSync()) as Map)
      : null;
  if (opt('update-baseline') != null) {
    final problems = base == null || opt('force') != null
        ? <String>[]
        : _grown(base, now, allowMoves: opt('allow-moves') != null);
    if (problems.isNotEmpty) {
      stdout.writeln('code_shape: baseline not updated, these grew:');
      for (var p in problems) {
        stdout.writeln('  $p');
      }
      exitCode = 1;
      return;
    }
    baseFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(now.toJson())}\n',
    );
    stdout.writeln('code_shape: wrote $baselinePath');
    return;
  }
  if (base == null) {
    stdout.writeln('code_shape: no $baselinePath; run with --update-baseline');
    exitCode = 1;
    return;
  }
  final problems = _grown(base, now, allowMoves: false);
  if (problems.isNotEmpty) {
    stdout.writeln(
      'code_shape: FAILED, grew against $baselinePath '
      '(list them with --list=<check> <package>):',
    );
    for (var p in problems) {
      stdout.writeln('  $p');
    }
    exitCode = 1;
    return;
  }
  if (_shrunk(base, now)) {
    stdout.writeln(
      'code_shape: OK; counts went down, lower the baseline '
      'with --update-baseline',
    );
  } else {
    stdout.writeln('code_shape: OK against $baselinePath');
  }
}

/// Reads the rules of the repository at [root] from its config and sets
/// [baselinePath] and [ratcheted].
(List<RuleSet>, HistoryRules) _rules(String root) {
  final config = LintConfig.of(root);
  baselinePath = config.baseline('code_shape');
  final sets = RuleSet.fromConfig(config.ruleSets);
  ratcheted = {'history', 'long-comment', ...sets.map((s) => s.check)}.toList()
    ..sort();
  return (
    sets,
    HistoryRules(names: config.historyNames, pointers: config.historyPointers),
  );
}

/// The words of [candidates] that name commits in the repository.
Set<String> knownCommits(String root, Set<String> candidates) {
  if (candidates.isEmpty) return {};
  final list = candidates.toList();
  // Process.runSync takes no stdin, so the list goes through a temp file.
  final tmp = File(
    '${Directory.systemTemp.createTempSync('code_shape').path}/in',
  )..writeAsStringSync(list.map((h) => '$h^{commit}').join('\n'));
  final r = Process.runSync('sh', [
    '-c',
    'git cat-file --batch-check < "\$1"',
    'sh',
    tmp.path,
  ], workingDirectory: root);
  tmp.parent.deleteSync(recursive: true);
  final out = <String>{};
  final lines = (r.stdout as String).split('\n');
  for (var k = 0; k < list.length && k < lines.length; k++) {
    if (lines[k].contains(' commit ')) out.add(list[k]);
  }
  return out;
}

/// Lines as `wc -l` counts them, plus an unterminated last line.
int lineCount(String text) {
  if (text.isEmpty) return 0;
  final n = '\n'.allMatches(text).length;
  return text.endsWith('\n') ? n : n + 1;
}

class Counts {
  Counts(this.size, this.packages);

  /// Files over the hard limit and their line counts.
  final Map<String, int> size;

  /// Package → check → hits.
  final Map<String, Map<String, int>> packages;

  Map<String, int> get totals {
    final t = {for (final c in ratcheted) c: 0};
    for (final p in packages.values) {
      p.forEach((c, n) => t[c] = t[c]! + n);
    }
    return t;
  }

  factory Counts.fromJson(Map j) => Counts(
    {
      for (final e in (j['size'] as Map).entries)
        e.key as String: e.value as int,
    },
    {
      for (final e in (j['packages'] as Map).entries)
        e.key as String: {
          for (final c in (e.value as Map).entries)
            c.key as String: c.value as int,
        },
    },
  );

  Map<String, Object> toJson() => {
    'about':
        'code_shape ratchet: files over 1,000 lines may not grow; '
        'per-package hit counts may not grow. Lower it with '
        '`dart tools/lint/code_shape.dart --update-baseline`.',
    'size': Map.fromEntries(
      size.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'packages': Map.fromEntries(
      packages.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
  };
}

Counts _counts(List<FileReport> reports) {
  final size = <String, int>{};
  final packages = <String, Map<String, int>>{};
  for (final r in reports) {
    if (r.lines > hardLimit) size[r.path] = r.lines;
    for (final h in r.hits) {
      final p = packages.putIfAbsent(r.package, () => {});
      p[h.check] = (p[h.check] ?? 0) + 1;
    }
  }
  return Counts(size, packages);
}

List<String> _grown(Counts base, Counts now, {required bool allowMoves}) {
  final out = <String>[];
  now.size.forEach((path, n) {
    final b = base.size[path];
    if (b == null) {
      out.add('size: $path has $n lines (limit $hardLimit)');
    } else if (n > b) {
      out.add('size: $path grew from $b to $n lines');
    }
  });
  if (allowMoves) {
    final bt = base.totals, nt = now.totals;
    for (final c in ratcheted) {
      if (nt[c]! > bt[c]!) {
        out.add('$c: tree total grew from ${bt[c]} to ${nt[c]}');
      }
    }
    return out;
  }
  now.packages.forEach((pkg, checks) {
    checks.forEach((c, n) {
      final b = base.packages[pkg]?[c] ?? 0;
      if (n > b) out.add('$c: $pkg grew from $b to $n');
    });
  });
  return out;
}

bool _shrunk(Counts base, Counts now) {
  for (final e in base.size.entries) {
    if ((now.size[e.key] ?? 0) < e.value) return true;
  }
  for (final p in base.packages.entries) {
    for (final c in p.value.entries) {
      if ((now.packages[p.key]?[c.key] ?? 0) < c.value) return true;
    }
  }
  return false;
}

void _list(List<FileReport> reports, List<String>? checks) {
  bool want(String c) => checks == null || checks.contains(c);
  for (final r in reports) {
    if (r.lines > hardLimit && want('size')) {
      stdout.writeln('${r.path}: size: ${r.lines} lines (limit $hardLimit)');
    } else if (r.lines > softLimit && want('soft')) {
      stdout.writeln('${r.path}: soft: ${r.lines} lines (target $softLimit)');
    }
    for (final h in r.hits) {
      if (want(h.check)) {
        stdout.writeln('${r.path}:${h.line}: ${h.check}/${h.rule}: ${h.text}');
      }
    }
    if (want('function')) {
      for (final f in r.functions) {
        stdout.writeln(
          '${r.path}:${f.start}: function: ${f.name} '
          '${f.lines} lines (limit $functionLimit)',
        );
      }
    }
  }
}

void _summary(List<FileReport> reports, Counts now) {
  final soft = <String, int>{}, hard = <String, int>{};
  for (final r in reports) {
    if (r.lines > softLimit) soft[r.package] = (soft[r.package] ?? 0) + 1;
    if (r.lines > hardLimit) hard[r.package] = (hard[r.package] ?? 0) + 1;
  }
  final pkgs = {...now.packages.keys, ...soft.keys}.toList()..sort();
  stdout.writeln(
    '${'package'.padRight(44)} >1000  >500  ${ratcheted.join('  ')}',
  );
  for (final p in pkgs) {
    final c = now.packages[p] ?? const {};
    stdout.writeln(
      '${p.padRight(44)} ${'${hard[p] ?? 0}'.padLeft(5)} '
      '${'${soft[p] ?? 0}'.padLeft(5)}  '
      '${[for (final k in ratcheted) '${c[k] ?? 0}'.padLeft(k.length)].join('  ')}',
    );
  }
  final rules = <String, int>{};
  for (final r in reports) {
    for (final h in r.hits) {
      final k = '${h.check}/${h.rule}';
      rules[k] = (rules[k] ?? 0) + 1;
    }
  }
  stdout.writeln('by rule:');
  for (final k in rules.keys.toList()..sort()) {
    stdout.writeln('  ${k.padRight(36)} ${rules[k]}');
  }
}

void _writeJson(List<FileReport> reports, String path) {
  File(path).writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert([
      for (final r in reports)
        {
          'path': r.path,
          'package': r.package,
          'lines': r.lines,
          'hits': [
            for (final h in r.hits)
              {
                'check': h.check,
                'rule': h.rule,
                'line': h.line,
                'text': h.text,
              },
          ],
          'functions': [
            for (final f in r.functions)
              {'name': f.name, 'line': f.start, 'lines': f.lines},
          ],
        },
    ]),
  );
}
