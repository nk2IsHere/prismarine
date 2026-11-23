// alloc counts the places where per-frame code allocates and ratchets them
// against the alloc baseline of the repository. Run it with --help for the
// usage.
import 'dart:convert';
import 'dart:io';

import 'src/alloc/markers.dart';
import 'src/alloc/program.dart';
import 'src/alloc/sdk.dart';
import 'src/alloc/walk.dart';
import 'src/config.dart';
import 'src/scope.dart';

const usage = r'''
alloc counts the places where per-frame code allocates and ratchets them
against the baseline in tools/lint/config.yaml (alloc_baseline.json by
default).

  dart tools/lint/alloc.dart [options]

Per-frame code is the code that the roots in the roots file reach: every
call the resolved program names (an instance call reaches the member's
overrides in the receiver's subtypes; a closure's body belongs to the
function making it; a tear-off makes its target reachable; a call through a
function value is followed no further).
  // alloc-cold: <reason>   above a function: a steady frame does not run it
                            (a load, a first use, a miss, an error path)
  // alloc: <reason>        on a place's line or the line above: it must
                            allocate, and why

Kinds:
  new      a constructor call that is not const
  literal  a list, set, map or record literal that is not const
  string   interpolation, concatenation, toString
  closure  a function expression; a tear-off of an instance method
  box      a double stored, passed or returned as Object, dynamic, num, a
           type parameter or a nullable type, or through a function value
  iterate  for-in over anything but a List; lazy Iterable views and copies
  async    a call of an async function or a generator; an await
  dynamic  a call or read on a dynamic receiver
  sdk      a dart: member that the SDK verdicts of the config do not list

Options:
  --list[=<kind>,...]   print every place (accepted: the marked ones with
                        their reasons; cold: the functions the walk stops at)
  --summary             counts per package and kind
  --why=<file>:<line>   the calls from a root to the function at that line
  --sdk-unknown         the unlisted dart: members by how often they occur
  --update-baseline     rewrite the baseline when nothing grew (--force:
                        whatever the counts)
  --json=<file>         write every place as JSON
  --packages=<a,b>      resolve only these package directories (default: the
                        alloc.packages list of the config, else the
                        pure-Dart packages of the workspace, and then the
                        alloc.flutter_packages list of the config)

A Flutter package resolves through its own package config. Run flutter pub
get in it first.

Exit codes: 0 clean against the baseline, 1 a count grew or a kind
appeared, 2 usage error.
''';

late final String baselinePath;
late final String rootsPath;
late final String sdkPath;
const kinds = [
  'new',
  'literal',
  'string',
  'closure',
  'box',
  'iterate',
  'async',
  'dynamic',
  'sdk',
];

Future<void> main(List<String> argv) async {
  final opts = <String, String>{};
  for (final a in argv) {
    final m = RegExp(r'^--([a-z-]+)(?:=(.*))?$').firstMatch(a);
    if (m == null || a == '--help') {
      stdout.write(usage);
      exit(a == '--help' ? 0 : 2);
    }
    opts[m[1]!] = m[2] ?? '';
  }
  const known = {
    'list',
    'summary',
    'why',
    'sdk-unknown',
    'update-baseline',
    'force',
    'json',
    'packages',
  };
  final unknown = opts.keys.where((k) => !known.contains(k));
  if (unknown.isNotEmpty) {
    stderr.writeln('alloc: unknown option --${unknown.first}');
    exit(2);
  }
  final root = repoRoot();
  final config = LintConfig.of(root);
  baselinePath = config.baseline('alloc');
  rootsPath = config.allocRoots;
  sdkPath = config.allocSdk;
  final packages =
      opts['packages']?.split(',') ??
      [
        ...config.allocPackages ?? _workspacePackages(root),
        ...config.allocFlutterPackages,
      ];
  for (final p in config.allocFlutterPackages) {
    if (packages.contains(p) &&
        !File('$root/$p/.dart_tool/package_config.json').existsSync()) {
      stderr.writeln(
        'alloc: $p has no package config. Run flutter pub get in $p.',
      );
      exit(2);
    }
  }
  final program = Program();
  await loadProgram(
    program,
    root,
    [
      for (final p in packages)
        if (Directory('$root/$p/lib').existsSync()) '$root/$p/lib',
    ],
    _packageOf,
    stderr.writeln,
  );
  final roots = _roots(root, program);
  final walk = Walk(program, SdkVerdicts.read('$root/$sdkPath'))..run(roots);
  final counted = walk.hits.where((h) => h.accepted == null).toList()
    ..sort(_byPlace);
  final counts = <String, Map<String, int>>{};
  for (final h in counted) {
    final p = counts.putIfAbsent(h.file.package, () => {});
    p[h.kind] = (p[h.kind] ?? 0) + 1;
  }

  if (opts['why'] case final at?) {
    _why(walk, program, at);
    return;
  }
  if (opts.containsKey('sdk-unknown')) {
    final n = <String, int>{};
    for (final h in counted.where((h) => h.kind == 'sdk')) {
      n[h.what] = (n[h.what] ?? 0) + 1;
    }
    final rows = n.entries.toList()..sort((a, b) => b.value - a.value);
    for (final r in rows) {
      stdout.writeln('${r.value.toString().padLeft(5)} ${r.key}');
    }
    return;
  }
  if (opts['list'] case final list?) {
    final want = list.isEmpty ? kinds.toSet() : list.split(',').toSet();
    for (final h in counted.where((h) => want.contains(h.kind))) {
      stdout.writeln('${h.place}: ${h.kind}: ${h.what}');
    }
    if (want.contains('accepted')) {
      final accepted = walk.hits.where((h) => h.accepted != null).toList()
        ..sort(_byPlace);
      for (final h in accepted) {
        stdout.writeln('${h.place}: ${h.kind}: ${h.what}: ${h.accepted}');
      }
    }
    if (want.contains('cold')) {
      for (final e in walk.cold.entries) {
        stdout.writeln('cold ${e.key}: ${e.value}');
      }
    }
  }
  if (opts['json'] case final path?) {
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert([
        for (final h in walk.hits)
          {
            'file': h.file.path,
            'line': h.line,
            'kind': h.kind,
            'what': h.what,
            'in': h.inside,
            'accepted': ?h.accepted,
          },
      ]),
    );
  }
  final total = {
    for (final k in kinds) k: counted.where((h) => h.kind == k).length,
  };
  stdout.writeln(
    'alloc: ${program.files.length} files, ${walk.from.length} functions '
    'reached from ${roots.length} roots (${walk.cold.length} cold); '
    '${counted.length} places: '
    '${[for (final k in kinds) '${total[k]} $k'].join(', ')}; '
    '${walk.hits.length - counted.length} accepted',
  );
  if (opts.containsKey('summary')) {
    for (final p in counts.keys.toList()..sort()) {
      final c = counts[p]!;
      stdout.writeln(
        '  $p: ${[for (final k in kinds)
          if (c[k] != null) '${c[k]} $k'].join(', ')}',
      );
    }
  }
  exit(_ratchet(root, counts, opts));
}

int _byPlace(Hit a, Hit b) {
  final f = a.file.path.compareTo(b.file.path);
  if (f != 0) return f;
  return a.line != b.line ? a.line - b.line : a.column - b.column;
}

/// Returns the package of [path] as `packages/<name>`, `apps/<name>` or
/// `tools/<name>`.
String _packageOf(String path) => path.split('/').take(2).join('/');

/// Returns the workspace members of the root pubspec.
List<String> _workspacePackages(String root) {
  final out = <String>[];
  var inList = false;
  for (final l in File('$root/pubspec.yaml').readAsLinesSync()) {
    if (l.startsWith('workspace:')) {
      inList = true;
    } else if (inList && l.trimLeft().startsWith('- ')) {
      out.add(l.trim().substring(2).trim());
    } else if (inList && l.isNotEmpty && !l.startsWith(' ')) {
      inList = false;
    }
  }
  return out;
}

/// Returns the entries of the roots file as function ids. Each line has the
/// form `<file>[#<Member>] <words>`, with the file relative to the
/// repository and `*` for any run of characters within a name. An entry
/// without a member covers every function in the file.
List<String> _roots(String root, Program program) {
  final out = <String>{};
  for (final raw in File('$root/$rootsPath').readAsLinesSync()) {
    final line = raw.split(' #').first.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final spec = line.split(RegExp(r'\s+')).first;
    final hash = spec.indexOf('#');
    final path = hash < 0 ? spec : spec.substring(0, hash);
    final member = hash < 0 ? null : spec.substring(hash + 1);
    final files = RegExp(
      '^${RegExp.escape(path).replaceAll(r'\*', '[^/]*')}\$',
    );
    var matched = 0;
    for (final d in program.decls.values) {
      if (!files.hasMatch(d.file.path)) continue;
      final name = d.id.substring(d.id.indexOf('::') + 2);
      if (member != null && name != member && !name.startsWith('$member.')) {
        continue;
      }
      out.add(d.id);
      matched++;
    }
    if (matched == 0) {
      stderr.writeln('alloc: root matches nothing: $spec');
      exit(2);
    }
  }
  return out.toList()..sort();
}

void _why(Walk walk, Program program, String at) {
  final m = RegExp(r'^(.*):(\d+)$').firstMatch(at);
  if (m == null) {
    stderr.writeln('alloc: --why wants <file>:<line>');
    exit(2);
  }
  final line = int.parse(m[2]!);
  Decl? best;
  for (final d in program.decls.values) {
    if (d.file.path != m[1]) continue;
    final end = d.file.lineOf(d.node.end);
    if (d.line <= line && line <= end) {
      if (best == null || d.line >= best.line) best = d;
    }
  }
  if (best == null) {
    stdout.writeln('alloc: no function at $at');
    exit(1);
  }
  if (!walk.from.containsKey(best.id)) {
    stdout.writeln('alloc: ${best.id} is not reached from a root');
    exit(1);
  }
  for (final id in walk.chain(best.id)) {
    final d = program.decls[id];
    stdout.writeln(d == null ? id : '${d.file.path}:${d.line}: $id');
  }
  final cold = Markers.of(best.file).cold(best.line);
  if (cold != null) stdout.writeln('(cold: $cold)');
}

int _ratchet(
  String root,
  Map<String, Map<String, int>> counts,
  Map<String, String> opts,
) {
  final file = File('$root/$baselinePath');
  final base = <String, Map<String, int>>{};
  if (file.existsSync()) {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final e in (json['packages'] as Map<String, Object?>).entries) {
      base[e.key] = (e.value as Map<String, Object?>).cast<String, int>();
    }
  }
  final grew = <String>[];
  var fell = false;
  for (final p in {...counts.keys, ...base.keys}) {
    for (final k in kinds) {
      final now = counts[p]?[k] ?? 0, was = base[p]?[k] ?? 0;
      if (now > was) grew.add('$k: $p grew from $was to $now');
      if (now < was) fell = true;
    }
  }
  if (opts.containsKey('update-baseline')) {
    if (grew.isNotEmpty && !opts.containsKey('force') && file.existsSync()) {
      stdout.writeln('alloc: baseline not updated, these grew:');
      grew.forEach(stdout.writeln);
      return 1;
    }
    final sorted = {
      for (final p in counts.keys.toList()..sort())
        p: {
          for (final k in kinds)
            if (counts[p]![k] != null) k: counts[p]![k],
        },
    };
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'about': 'alloc ratchet: per-package counts of allocation places in per-frame code may not grow. Lower it with `dart tools/lint/alloc.dart --update-baseline`.', 'packages': sorted})}\n',
    );
    stdout.writeln('alloc: wrote $baselinePath');
    return 0;
  }
  if (!file.existsSync()) {
    stdout.writeln('alloc: no $baselinePath; run with --update-baseline');
    return 1;
  }
  if (grew.isNotEmpty) {
    stdout.writeln(
      'alloc: FAILED, grew against $baselinePath (list them with '
      '--list=<kind>; a place that must allocate takes `// alloc: <reason>`):',
    );
    for (final g in grew) {
      stdout.writeln('  $g');
    }
    return 1;
  }
  stdout.writeln(
    fell
        ? 'alloc: OK; counts went down, lower the baseline with '
              '--update-baseline'
        : 'alloc: OK against $baselinePath',
  );
  return 0;
}
