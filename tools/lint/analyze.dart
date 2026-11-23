// analyze runs the analyzer, clippy and the formatters over the code of the
// repository and ratchets the results against the analyze baseline. Run it
// with --help for the usage.
import 'dart:convert';
import 'dart:io';

import 'src/config.dart';
import 'src/scope.dart';

const usage = r'''
analyze runs the analyzer, clippy and the formatters over our code and
ratchets the results against the baseline in tools/lint/config.yaml.

  dart tools/lint/analyze.dart [options]

Checks (each counted per package and diagnostic code):
  dart     `dart analyze` at the workspace root: every pure-Dart package
           and the scripts under tools/ outside a package
  flutter  `dart analyze` in each Flutter package (resolved ones only:
           run `flutter pub get` there first, or point --flutter-root at a
           synced build mirror)
  clippy   `cargo clippy --all-targets` for each of our Rust crates
  format   files `dart format` and `cargo fmt` would change
The analysis options are tools/lint/analysis/*.yaml, included by every
package's analysis_options.yaml.

Options:
  --only=dart,flutter,clippy,format   run these checks (default: all)
  --flutter-root=<dir>  a tree whose Flutter packages are resolved (the
                        gate's build mirror); default: this repository
  --target-dir=<dir>    cargo's target dir (default: each crate's own)
  --list                print every diagnostic
  --update-baseline     rewrite the baseline when nothing grew; packages a
                        run skipped keep their entries
  --apply-format        format our code in place (`dart format` on the files
                        in scope, `cargo fmt` in each crate); the result is
                        layout only, which same_code confirms

The ratchet: no package's count for a code may grow, and no new code may
appear in it. A package or check that was skipped (not resolved, no
toolchain) is reported and left out of the comparison.

Exit codes: 0 clean against the baseline, 1 something grew, 2 usage.
''';

String get baselinePath => LintConfig.of(repoRoot()).baseline('analyze');
const checks = ['dart', 'flutter', 'clippy', 'format'];

// The extra cargo arguments for crates that only build for one target.
Map<String, List<String>> get crateArgs => LintConfig.of(repoRoot()).crateArgs;

class Diag {
  Diag(this.package, this.key, this.where, this.message);
  final String package;

  /// The key of the form `<check>:<code>`, such as `dart:unused_import` or
  /// `clippy:needless_range_loop`.
  final String key;
  final String where;
  final String message;
}

void main(List<String> args) {
  String? opt(String name) {
    for (final a in args) {
      if (a == '--$name') return '';
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  const known = [
    'help',
    'only',
    'flutter-root',
    'target-dir',
    'list',
    'update-baseline',
    'apply-format',
  ];
  for (final a in args) {
    if (!a.startsWith('--') ||
        !known.contains(a.substring(2).split('=').first)) {
      stderr.writeln('analyze: unknown argument $a');
      exit(2);
    }
  }
  if (opt('help') != null) {
    stdout.write(usage);
    return;
  }
  if (opt('apply-format') != null) {
    _applyFormat(repoRoot());
    return;
  }
  final only = opt('only')?.split(',') ?? checks;
  final run = _Run(repoRoot(), opt('flutter-root'), opt('target-dir'));
  final steps = {
    'dart': run.dart,
    'flutter': run.flutter,
    'clippy': run.clippy,
    'format': run.format,
  };
  for (final c in checks.where(only.contains)) {
    final sw = Stopwatch()..start();
    steps[c]!();
    final s = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);
    stdout.writeln('analyze: $c $s s');
  }
  if (opt('list') != null) {
    for (final d in run.diags) {
      stdout.writeln('${d.where}: ${d.key}: ${d.message}');
    }
  }
  for (final s in run.skipped) {
    stdout.writeln('analyze: skipped $s');
  }
  final totals = <String, int>{};
  for (final d in run.diags) {
    final c = d.key.split(':').first;
    totals[c] = (totals[c] ?? 0) + 1;
  }
  final byCheck = checks
      .where(only.contains)
      .map((c) => '$c ${totals[c] ?? 0}')
      .join(', ');
  stdout.writeln('analyze: ${run.diags.length} diagnostics ($byCheck)');
  _ratchet(run, update: opt('update-baseline') != null);
}

/// One run of the checks with the findings and the packages that were
/// analysed and skipped.
class _Run {
  _Run(this.root, String? flutterRoot, this.targetDir)
    : flutterRoot = flutterRoot ?? root,
      pkgDirs = packageDirs(root);
  final String root;
  final String flutterRoot;
  final String? targetDir;
  final Set<String> pkgDirs;
  final diags = <Diag>[];

  /// `<check>|<package>` for every package that a check analysed.
  final ran = <String>{};
  final skipped = <String>[];

  // The directories with Dart code outside any package, analysed from the
  // root.
  static List<String> get looseDirs => LintConfig.of(repoRoot()).looseDirs;

  void dart() {
    final r = _run('dart', ['analyze', '--format=machine'], root);
    diags.addAll(_machine(r.stdout + r.stderr, root, '', 'dart', pkgDirs));
    for (final p in pkgDirs.where((p) => !_isFlutter(root, p))) {
      ran.add('dart|$p');
    }
    ran.addAll(looseDirs.map((d) => 'dart|$d'));
  }

  void flutter() {
    for (final p in pkgDirs.where((p) => _isFlutter(root, p))) {
      final dir = '$flutterRoot/$p';
      if (!File('$dir/.dart_tool/package_config.json').existsSync()) {
        skipped.add('flutter $p (not resolved under $flutterRoot)');
        continue;
      }
      final r = _run('dart', ['analyze', '--format=machine', '.'], dir);
      diags.addAll(
        _machine(r.stdout + r.stderr, dir, '$p/', 'flutter', pkgDirs),
      );
      ran.add('flutter|$p');
    }
  }

  void clippy() {
    for (final c in _crates(root)) {
      final r = _run('cargo', [
        'clippy',
        '--all-targets',
        '--message-format=json',
        '--quiet',
        ...?crateArgs[c],
        if (targetDir != null) ...[
          '--target-dir',
          '$targetDir/${c.replaceAll('/', '_')}',
        ],
      ], '$root/$c');
      final found = _clippy(r.stdout, c);
      if (r.exitCode != 0 && found.isEmpty) {
        skipped.add('clippy $c (cargo failed: ${_firstError(r.stderr)})');
        continue;
      }
      diags.addAll(found);
      ran.add('clippy|$c');
    }
  }

  void format() {
    final files = trackedCodeFiles(root)
        .where((f) => f.endsWith('.dart'))
        .where((f) => !isGenerated(File('$root/$f').readAsStringSync()))
        .toList();
    final r = _run('dart', [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      ...files,
    ], root);
    for (final l in (r.stdout as String).split('\n')) {
      if (!l.startsWith('Changed ')) continue;
      final f = l.substring(8).trim();
      diags.add(Diag(packageOf(f, pkgDirs), 'format:dart', f, 'not formatted'));
    }
    ran.addAll(pkgDirs.map((p) => 'format|$p'));
    ran.addAll(looseDirs.map((d) => 'format|$d'));
    for (final c in _crates(root)) {
      final f = _run('cargo', ['fmt', '--check', '--', '-l'], '$root/$c');
      final out = (f.stdout as String).trim();
      if (f.exitCode != 0 && out.isEmpty) {
        skipped.add('format $c (cargo fmt failed: ${_firstError(f.stderr)})');
        continue;
      }
      for (final l in out.split('\n').where((l) => l.isNotEmpty)) {
        final rel = l.startsWith('/') ? l.substring(root.length + 1) : '$c/$l';
        diags.add(Diag(c, 'format:rust', rel, 'not formatted'));
      }
    }
  }

  bool wasRun(String pkg, String key) =>
      ran.contains('${key.split(':').first}|$pkg');
}

void _applyFormat(String root) {
  final files = trackedCodeFiles(root)
      .where((f) => f.endsWith('.dart'))
      .where((f) => !isGenerated(File('$root/$f').readAsStringSync()))
      .toList();
  final r = _run('dart', ['format', ...files], root);
  stdout.writeln((r.stdout as String).trim().split('\n').last);
  for (final c in _crates(root)) {
    final f = _run('cargo', ['fmt'], '$root/$c');
    stdout.writeln('cargo fmt $c: ${f.exitCode == 0 ? 'done' : f.stderr}');
  }
}

void _ratchet(_Run run, {required bool update}) {
  final now = <String, Map<String, int>>{};
  for (final d in run.diags) {
    final m = now.putIfAbsent(d.package, () => {});
    m[d.key] = (m[d.key] ?? 0) + 1;
  }
  final baseFile = File('${run.root}/$baselinePath');
  final base = <String, Map<String, int>>{};
  if (baseFile.existsSync()) {
    final j = jsonDecode(baseFile.readAsStringSync())['packages'] as Map;
    j.forEach((pkg, codes) {
      base[pkg as String] = {
        for (final e in (codes as Map).entries) e.key as String: e.value as int,
      };
    });
  }
  final grown = <String>[];
  now.forEach((pkg, codes) {
    codes.forEach((key, n) {
      final b = base[pkg]?[key] ?? 0;
      if (n > b) grown.add('$pkg $key: $b → $n');
    });
  });
  var shrunk = false;
  base.forEach((pkg, codes) {
    codes.forEach((key, b) {
      if (run.wasRun(pkg, key) && (now[pkg]?[key] ?? 0) < b) shrunk = true;
    });
  });
  void listGrown(String header) {
    stdout.writeln(header);
    for (final g in grown) {
      stdout.writeln('  $g');
    }
    exitCode = 1;
  }

  if (update) {
    if (grown.isNotEmpty && baseFile.existsSync()) {
      listGrown('analyze: baseline not updated, these grew:');
      return;
    }
    // Entries of checks that ran are replaced; the rest are kept.
    final next = <String, Map<String, int>>{};
    base.forEach((pkg, codes) {
      codes.forEach((key, n) {
        if (!run.wasRun(pkg, key)) next.putIfAbsent(pkg, () => {})[key] = n;
      });
    });
    now.forEach((pkg, codes) => next.putIfAbsent(pkg, () => {}).addAll(codes));
    final sorted = {
      for (final p in next.keys.toList()..sort())
        p: {for (final k in next[p]!.keys.toList()..sort()) k: next[p]![k]!},
    };
    const about =
        'analyze ratchet: per package, diagnostics per code may not grow. '
        'Lower it with `dart tools/lint/analyze.dart --update-baseline`.';
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert({'about': about, 'packages': sorted});
    baseFile.writeAsStringSync('$json\n');
    stdout.writeln('analyze: wrote $baselinePath');
    return;
  }
  if (grown.isNotEmpty) {
    listGrown('analyze: FAILED, grew against $baselinePath (see --list):');
  } else if (shrunk) {
    stdout.writeln(
      'analyze: OK; counts went down, lower the baseline with '
      '--update-baseline',
    );
  } else {
    stdout.writeln('analyze: OK against $baselinePath');
  }
}

ProcessResult _run(String exe, List<String> args, String dir) =>
    Process.runSync(
      exe,
      args,
      workingDirectory: dir,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

bool _isFlutter(String root, String pkg) {
  final f = File('$root/$pkg/pubspec.yaml');
  return f.existsSync() && f.readAsStringSync().contains('sdk: flutter');
}

List<String> _crates(String root) => packageDirs(
  root,
).where((p) => File('$root/$p/Cargo.toml').existsSync()).toList()..sort();

// Parses the lines of `dart analyze --format=machine`, each of the form
// SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE.
Iterable<Diag> _machine(
  String out,
  String dir,
  String prefix,
  String check,
  Set<String> pkgDirs,
) sync* {
  for (final l in out.split('\n')) {
    final f = l.split('|');
    if (f.length < 8 || !const {'INFO', 'WARNING', 'ERROR'}.contains(f[0])) {
      continue;
    }
    var path = f[3];
    if (path.startsWith('$dir/')) {
      path = '$prefix${path.substring(dir.length + 1)}';
    }
    yield Diag(
      packageOf(path, pkgDirs),
      '$check:${f[2].toLowerCase()}',
      '$path:${f[4]}',
      '${f[0].toLowerCase()} ${f.sublist(7).join('|')}',
    );
  }
}

// Parses the output of `cargo clippy --message-format=json` into the
// diagnostics whose primary span is in the crate and not in a dependency.
List<Diag> _clippy(String out, String crate) {
  final diags = <Diag>[];
  final seen = <String>{};
  for (final l in out.split('\n')) {
    if (!l.startsWith('{')) continue;
    final j = jsonDecode(l) as Map;
    if (j['reason'] != 'compiler-message') continue;
    final m = j['message'] as Map;
    final level = m['level'];
    if (level != 'warning' && level != 'error') continue;
    final spans = (m['spans'] as List).cast<Map>();
    final primary = spans.where((s) => s['is_primary'] == true).firstOrNull;
    if (primary == null) continue;
    final file = primary['file_name'] as String;
    if (file.startsWith('/')) continue; // a dependency's source
    final code = (m['code'] as Map?)?['code'] as String? ?? level as String;
    final where = '$crate/$file:${primary['line_start']}';
    // --all-targets reports the warning of a lib once per target that builds
    // it.
    if (!seen.add('$where $code')) continue;
    diags.add(
      Diag(
        crate,
        'clippy:${code.replaceFirst('clippy::', '')}',
        where,
        '$level ${m['message']}',
      ),
    );
  }
  return diags;
}

String _firstError(Object? stderr) {
  final l =
      '$stderr'.split('\n').where((l) => l.contains('error')).firstOrNull ??
      '$stderr';
  return l.length > 120 ? '${l.substring(0, 120)}…' : l;
}
