// privacy_check: fails when the public tree holds private material — the
// owner's account names, hosts, home paths, emails, secrets, or a
// password-like assignment.
//
//   dart tools/lint/privacy_check.dart [--root=<tree>] [--strict] [--generic-only]
//
// Scans the tree's tracked files plus untracked ones that are not ignored.
// The private patterns are not in this file: they come from
// <private>/config/privacy-patterns.txt, and every value in
// <private>/secrets/*.env is added as a plain-text pattern. A pattern line
// that starts with `code: ` applies only to the files that the code lints
// check, outside the comment_check_exempt paths of the config, where the
// files of the lint quote the words. Docs can mention a word that code must
// not use. <private> is the directory in the variable of
// privacy.private_env in the config. Without
// it, the check takes `private/` beside the main checkout of the git
// repository of the tree, then the first `private/` with a `config/` above
// the tree. The password and key checks below are generic and need no
// private config.
//
// The paths in the privacy.pending file of the config hold material that a
// later change removes or rewrites. Their hits are reported as pending and
// fail the check only with --strict. Without private config the check exits
// with 2, unless --generic-only is given.
//
// Exit codes: 0 clean, 1 findings, 2 no private config.
import 'dart:convert';
import 'dart:io';

import 'src/config.dart';
import 'src/scope.dart';

class Pattern {
  Pattern(this.re, this.label, {this.secret = false, this.codeOnly = false});
  final RegExp re;
  final String label;

  /// A secret's value: the report masks the matched text.
  final bool secret;

  /// Applies to code files only.
  final bool codeOnly;
}

/// Password-like assignments and key material, whatever the machine.
final generic = <Pattern>[
  Pattern(
    RegExp(
      r'''\b(password|passwd|pwd|passphrase|secret|api[_-]?key|access[_-]?token)\s*[:=]\s*['"]?(?!(true|false|null|none|nil|required)\b)[^\s'"$<{(]{6,}''',
      caseSensitive: false,
    ),
    'password-like assignment',
  ),
  Pattern(RegExp(r'''/rp\s+['"]?[^\s'"$<]'''), 'schtasks /rp with a literal'),
  Pattern(
    RegExp(r'''-(Password|Pass)\s+['"][^'"$<]''', caseSensitive: false),
    'password argument with a literal',
  ),
  Pattern(RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'), 'private key'),
  Pattern(RegExp(r'\bgh[pousr]_[A-Za-z0-9]{30,}'), 'GitHub token'),
  Pattern(RegExp(r'\bAKIA[0-9A-Z]{16}\b'), 'AWS key id'),
  Pattern(RegExp(r'\bsk-[A-Za-z0-9_-]{32,}'), 'API secret key'),
];

void main(List<String> args) {
  var root = '';
  var strict = false;
  var genericOnly = false;
  for (final a in args) {
    if (a.startsWith('--root=')) {
      root = a.substring(7);
    } else if (a == '--strict') {
      strict = true;
    } else if (a == '--generic-only') {
      genericOnly = true;
    } else {
      stderr.writeln(
        'usage: dart tools/lint/privacy_check.dart [--root=<tree>] [--strict] [--generic-only]',
      );
      exit(64);
    }
  }
  if (root.isEmpty) {
    final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
    if (r.exitCode != 0) {
      stderr.writeln('privacy_check: not in a git tree (pass --root)');
      exit(64);
    }
    root = (r.stdout as String).trim();
  }
  setRepoRoot(root);
  final config = LintConfig.of(root);

  final patterns = <Pattern>[...generic];
  final priv = privateDir(root, config.privateEnv);
  if (priv == null) {
    if (!genericOnly) {
      stderr.writeln(
        'privacy_check: no private config (set ${config.privateEnv}, or check '
        'out the private repo at <repo>/private); --generic-only runs the '
        'generic checks alone',
      );
      exit(2);
    }
  } else {
    final f = File('$priv/config/privacy-patterns.txt');
    if (!f.existsSync() && !genericOnly) {
      stderr.writeln(
        'privacy_check: $priv/config/privacy-patterns.txt is missing',
      );
      exit(2);
    }
    if (f.existsSync()) patterns.addAll(readPatterns(f));
    patterns.addAll(secretPatterns(priv));
  }

  final pending = readPending('$root/${config.privacyPending}');
  final files = listFiles(root);
  var findings = 0;
  var pendingHits = 0;
  final pendingFiles = <String>{};
  for (final rel in files) {
    final file = File('$root/$rel');
    if (!file.existsSync()) continue; // deleted in the work tree
    // Its own generic patterns would match themselves.
    if (rel == 'tools/lint/privacy_check.dart') continue;
    final bytes = file.readAsBytesSync();
    if (bytes.length > 8 << 20 || bytes.take(8000).contains(0)) continue;
    final text = utf8.decode(bytes, allowMalformed: true);
    final isPending = pending.any((p) => rel == p || rel.startsWith(p));
    final isCode =
        excludedBecause(rel) == null &&
        !config.commentCheckExempt.any(rel.startsWith);
    final lines = const LineSplitter().convert(text);
    for (var i = 0; i < lines.length; i++) {
      for (final p in patterns) {
        if (p.codeOnly && !isCode) continue;
        final m = p.re.firstMatch(lines[i]);
        if (m == null) continue;
        if (isPending) {
          pendingHits++;
          pendingFiles.add(rel);
          continue;
        }
        findings++;
        stdout.writeln(
          '$rel:${i + 1}: [${p.label}] ${excerpt(lines[i], m, p)}',
        );
      }
    }
  }
  if (pendingHits > 0) {
    stdout.writeln(
      'privacy_check: $pendingHits hit(s) in ${pendingFiles.length} file(s) '
      'under paths pending a later change (${config.privacyPending})'
      '${strict ? '' : '; not failing (--strict to fail)'}',
    );
    if (strict) {
      for (final f in pendingFiles.toList()..sort()) {
        stdout.writeln('  pending: $f');
      }
    }
  }
  final failed = findings + (strict ? pendingHits : 0);
  stdout.writeln(
    failed == 0
        ? 'privacy_check: clean (${files.length} files, ${patterns.length} patterns'
              '${priv == null ? ', generic only' : ''})'
        : 'privacy_check: $findings finding(s)'
              '${strict && pendingHits > 0 ? ' and $pendingHits pending hit(s)' : ''}',
  );
  exit(failed == 0 ? 0 : 1);
}

String? privateDir(String root, String envName) {
  final env = Platform.environment[envName];
  if (env != null && env.isNotEmpty) return env;
  // A worktree outside the main checkout takes the private repo beside the
  // main checkout before any other `private/` above it.
  final common = Process.runSync('git', [
    '-C',
    root,
    'rev-parse',
    '--path-format=absolute',
    '--git-common-dir',
  ]);
  if (common.exitCode == 0) {
    final main = Directory((common.stdout as String).trim()).parent.path;
    if (Directory('$main/private/config').existsSync()) return '$main/private';
  }
  var d = Directory(root).absolute;
  while (true) {
    if (Directory('${d.path}/private/config').existsSync()) {
      return '${d.path}/private';
    }
    final p = d.parent;
    if (p.path == d.path) return null;
    d = p;
  }
}

List<Pattern> readPatterns(File f) {
  final out = <Pattern>[];
  for (var line in f.readAsLinesSync()) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    var label = 'private pattern';
    final at = line.indexOf(' ## ');
    if (at >= 0) {
      label = line.substring(at + 4).trim();
      line = line.substring(0, at).trim();
    }
    var codeOnly = false;
    if (line.startsWith('code: ')) {
      codeOnly = true;
      line = line.substring(6).trim();
    }
    var caseSensitive = true;
    if (line.startsWith('(?i)')) {
      caseSensitive = false;
      line = line.substring(4);
    }
    out.add(
      Pattern(
        RegExp(line, caseSensitive: caseSensitive),
        label,
        codeOnly: codeOnly,
      ),
    );
  }
  return out;
}

/// Every value in secrets/*.env (4 characters or more) as a plain pattern.
List<Pattern> secretPatterns(String priv) {
  final d = Directory('$priv/secrets');
  if (!d.existsSync()) return const [];
  final out = <Pattern>[];
  for (final f in d.listSync().whereType<File>()) {
    if (!f.path.endsWith('.env')) continue;
    final name = f.path.split('/').last;
    for (final raw in f.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      var v = line.substring(eq + 1).trim();
      if (v.length >= 2 &&
          ((v.startsWith('"') && v.endsWith('"')) ||
              (v.startsWith("'") && v.endsWith("'")))) {
        v = v.substring(1, v.length - 1);
      }
      if (v.length < 4) continue;
      out.add(
        Pattern(
          RegExp(RegExp.escape(v)),
          'secret ${line.substring(0, eq)} from secrets/$name',
          secret: true,
        ),
      );
    }
  }
  return out;
}

List<String> readPending(String path) {
  final f = File(path);
  if (!f.existsSync()) return const [];
  return [
    for (final l in f.readAsLinesSync())
      if (l.trim().isNotEmpty && !l.trim().startsWith('#'))
        l.split('#').first.trim(),
  ].where((l) => l.isNotEmpty).toList();
}

List<String> listFiles(String root) {
  final r = Process.runSync('git', [
    '-C',
    root,
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ]);
  if (r.exitCode != 0) {
    stderr.writeln('privacy_check: git ls-files failed: ${r.stderr}');
    exit(64);
  }
  return (r.stdout as String)
      .split('\x00')
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
}

/// The line around the match, the match itself masked for a secret.
String excerpt(String line, RegExpMatch m, Pattern p) {
  final from = (m.start - 40).clamp(0, line.length);
  final to = (m.end + 40).clamp(0, line.length);
  final hit = p.secret ? '<secret>' : m.group(0)!;
  return '${from > 0 ? '…' : ''}${line.substring(from, m.start)}$hit'
      '${line.substring(m.end, to)}${to < line.length ? '…' : ''}';
}
