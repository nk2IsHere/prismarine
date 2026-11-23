// same_code: proves that a commit range changes only comments, whitespace
// and docs, so it cannot change behaviour. Usage: --help.
import 'dart:convert';
import 'dart:io';

import 'src/lexer.dart';

const usage = r'''
same_code: proves that a commit range changes only comments, whitespace
and docs, so it cannot change behaviour.

  dart tools/lint/same_code.dart <base> [<head>] [--each]
  dart tools/lint/same_code.dart <base>..<head> [--each]

For every file the range changes, the code tokens of both versions are
compared with comments and whitespace removed:
  - Dart, Rust and C-like files (GLSL, .fmat, C headers): exact lexers
    (src/lexer.dart; the Dart one matches the SDK scanner on every file
    of the tree);
  - Markdown files: allowed, they are not code;
  - anything else changed, added, deleted or renamed: not proven.
String literals are compared by text, so a changed message is a change.
Layout-only edits pass: trailing commas where they cannot matter, `> >`
for `>>` in type arguments, Dart's import order and quote style where the
value is the same (what `dart format` and `dart fix` for
directives_ordering and prefer_single_quotes produce). A Rust file that
differs is compared again after rustfmt has formatted both versions
(rustfmt keeps meaning; it also adds `;` after a final `return`, braces
closure bodies and sorts `use` and `mod` items), so `cargo fmt`'s output
passes too.

--each checks every commit of the range on its own and lists which ones
are comment-only (the range result still decides the exit code).

Exit codes: 0 same code, 1 a code change (or an unprovable file), 2 usage.
''';

void main(List<String> args) {
  if (args.contains('--help')) {
    stdout.write(usage);
    return;
  }
  final each = args.contains('--each');
  final rest = args.where((a) => !a.startsWith('--')).toList();
  String base, head;
  if (rest.length == 1 && rest.first.contains('..')) {
    final parts = rest.first.split('..');
    base = parts.first;
    head = parts.last.isEmpty ? 'HEAD' : parts.last;
  } else if (rest.isNotEmpty && rest.length <= 2) {
    base = rest[0];
    head = rest.length == 2 ? rest[1] : 'HEAD';
  } else {
    stderr.writeln('usage: same_code.dart <base> [<head>] [--each]');
    exit(2);
  }
  if (each) {
    final revs = _git([
      'rev-list',
      '--reverse',
      '$base..$head',
    ]).split('\n').where((l) => l.isNotEmpty);
    for (final c in revs) {
      final r = compareRange('$c^', c);
      final subject = _git(['log', '-1', '--format=%h %s', c]).trim();
      stdout.writeln('${r.same ? 'same   ' : 'CHANGED'} $subject');
    }
  }
  final r = compareRange(base, head);
  for (final l in r.lines) {
    stdout.writeln(l);
  }
  stdout.writeln(
    r.same
        ? 'same_code: $base..$head changes only comments, whitespace and docs '
              '(${r.files} files)'
        : 'same_code: $base..$head changes code',
  );
  exitCode = r.same ? 0 : 1;
}

class RangeResult {
  RangeResult(this.same, this.files, this.lines);
  final bool same;
  final int files;
  final List<String> lines;
}

RangeResult compareRange(String base, String head) {
  final diff = _git([
    'diff',
    '--name-status',
    '--no-renames',
    '-z',
    base,
    head,
  ]).split('\x00').where((s) => s.isNotEmpty).toList();
  final lines = <String>[];
  var same = true;
  var files = 0;
  for (var k = 0; k + 1 < diff.length; k += 2) {
    final status = diff[k], path = diff[k + 1];
    files++;
    if (path.endsWith('.md')) {
      lines.add('  doc      $path');
      continue;
    }
    if (status != 'M') {
      lines.add(
        '  ${status == 'A'
            ? 'added'
            : status == 'D'
            ? 'deleted'
            : status}    $path',
      );
      same = false;
      continue;
    }
    final lang = langOf(path);
    if (lang == null || !isExact(lang)) {
      lines.add('  unproven $path (no exact lexer for this file type)');
      same = false;
      continue;
    }
    final a = _show(base, path), b = _show(head, path);
    var diffAt = firstCodeDifference(a, b, lang);
    var how = '';
    if (diffAt != null && lang == Lang.rust) {
      final edition = _edition(head, path);
      final fa = rustfmt(a, edition), fb = rustfmt(b, edition);
      if (fa != null && fb != null) {
        diffAt = firstCodeDifference(fa, fb, lang);
        how = ' (after rustfmt)';
      }
    }
    if (diffAt == null) {
      lines.add('  same     $path$how');
    } else {
      lines.add('  CHANGED  $path$how: $diffAt');
      same = false;
    }
  }
  return RangeResult(same, files, lines);
}

/// Where the code tokens of [a] and [b] first differ, or null when they are
/// the same.
String? firstCodeDifference(String a, String b, Lang lang) {
  final ta = normalise(lex(a, lang), lang);
  final tb = normalise(lex(b, lang), lang);
  final n = ta.length < tb.length ? ta.length : tb.length;
  for (var k = 0; k < n; k++) {
    if (ta[k].kind != tb[k].kind || ta[k].text != tb[k].text) {
      return 'line ${ta[k].line} `${_short(ta[k].text)}` → '
          'line ${tb[k].line} `${_short(tb[k].text)}`';
    }
  }
  if (ta.length != tb.length) {
    return ta.length > tb.length
        ? 'tokens removed from line ${ta[n].line}'
        : 'tokens added at line ${tb[n].line}';
  }
  return null;
}

/// The code tokens of [toks] as the comparison sees them: no comments, `>>`
/// and `>>>` as single `>` tokens, trailing commas dropped where they don't
/// count, Dart strings in single quotes where that keeps their value (see
/// [singleQuoted]), and a Dart file's leading import, export and part
/// directives in sorted order (their order has no meaning; `dart fix` sorts
/// them for directives_ordering). Splitting `>` runs is safe because both versions
/// compile: `> >` only parses where it closes type arguments, which is what
/// a formatter splits.
List<Tok> normalise(List<Tok> toks, Lang lang) {
  final code = <Tok>[];
  for (final t in toks) {
    if (!t.isCode) continue;
    if (t.kind == TokKind.punct && (t.text == '>>' || t.text == '>>>')) {
      for (var k = 0; k < t.text.length; k++) {
        code.add(Tok(TokKind.punct, '>', t.line, t.line));
      }
    } else if (lang == Lang.dart && t.kind == TokKind.string) {
      code.add(Tok(TokKind.string, singleQuoted(t.text), t.line, t.endLine));
    } else {
      code.add(t);
    }
  }
  final out = dropTrailingCommas(code);
  return lang == Lang.dart ? sortDirectives(out) : out;
}

/// A double-quoted Dart string with no quote or backslash inside, written
/// with single quotes (the same value; `dart fix` makes this change for
/// prefer_single_quotes). Other literals are returned as they are.
String singleQuoted(String lit) {
  if (lit.length < 2 || !lit.startsWith('"') || lit.startsWith('"""')) {
    return lit;
  }
  final inner = lit.substring(1, lit.length - 1);
  if (inner.contains("'") || inner.contains('"') || inner.contains(r'\')) {
    return lit;
  }
  return "'$inner'";
}

/// [code] with the run of import/export/part directives at the top of a
/// Dart file (after an optional `library` directive and its annotations)
/// sorted by their text.
List<Tok> sortDirectives(List<Tok> code) {
  var k = 0;
  bool startsDirective(int at) =>
      at < code.length &&
      code[at].kind == TokKind.word &&
      const {'import', 'export', 'part'}.contains(code[at].text) &&
      !(code[at].text == 'part' &&
          at + 1 < code.length &&
          code[at + 1].text == 'of');
  int statementEnd(int at) {
    while (at < code.length && code[at].text != ';') {
      at++;
    }
    return at + 1;
  }

  // A leading `library` directive, with any annotations before it.
  if (k < code.length && (code[k].text == 'library' || code[k].text == '@')) {
    final end = statementEnd(k);
    if (code
        .sublist(k, end.clamp(0, code.length))
        .any((t) => t.text == 'library')) {
      k = end;
    }
  }
  final start = k;
  final directives = <List<Tok>>[];
  while (startsDirective(k)) {
    final end = statementEnd(k);
    directives.add(code.sublist(k, end.clamp(0, code.length)));
    k = end;
  }
  if (directives.length < 2) return code;
  String key(List<Tok> d) => d.map((t) => t.text).join(' ');
  directives.sort((x, y) => key(x).compareTo(key(y)));
  return [
    ...code.sublist(0, start),
    for (final d in directives) ...d,
    ...code.sublist(k.clamp(0, code.length)),
  ];
}

// Words before `(` that make a parenthesised group an expression, a pattern
// or a condition rather than an argument or parameter list.
const _notCallee = {
  'return',
  'yield',
  'await',
  'in',
  'case',
  'throw',
  'else',
  'when',
  'is',
  'as',
  'if',
  'while',
  'for',
  'switch',
  'match',
  'let',
  'mut',
  'break',
  'ref',
  'move',
  'const',
  'final',
  'var',
  'and',
  'or',
  'not',
};

/// [code] without the trailing commas that don't change meaning: before `]`
/// and `}` always, and before `)` when the group holds another comma or is
/// an argument or parameter list (the `(` follows a callee name, `)`, `]` or
/// `>`). `(x,)` stays: in Dart a one-field record, in Rust a one-tuple.
List<Tok> dropTrailingCommas(List<Tok> code) {
  final drop = <int>{};
  final open = <int>[]; // indices of unclosed brackets
  final commas = <int>[]; // depth-0 commas seen in each open group
  for (var k = 0; k < code.length; k++) {
    final t = code[k];
    if (t.kind != TokKind.punct) continue;
    switch (t.text) {
      case '(' || '[' || '{':
        open.add(k);
        commas.add(0);
      case ',':
        if (commas.isNotEmpty) commas[commas.length - 1]++;
      case ')' || ']' || '}':
        if (open.isEmpty) break;
        final o = open.removeLast();
        final n = commas.removeLast();
        final prev = k - 1;
        if (prev <= o ||
            code[prev].text != ',' ||
            code[prev].kind != TokKind.punct) {
          break;
        }
        if (t.text != ')') {
          drop.add(prev);
          break;
        }
        final before = o > 0 ? code[o - 1] : null;
        final callee =
            before != null &&
            ((before.kind == TokKind.word &&
                    !_notCallee.contains(before.text)) ||
                (before.kind == TokKind.punct &&
                    (before.text == ')' ||
                        before.text == ']' ||
                        before.text == '>')));
        if (n > 1 || callee) drop.add(prev);
    }
  }
  if (drop.isEmpty) return code;
  return [
    for (var k = 0; k < code.length; k++)
      if (!drop.contains(k)) code[k],
  ];
}

/// [src] formatted by rustfmt for [edition], or null when rustfmt fails
/// (not installed, or the source doesn't parse).
String? rustfmt(String src, String edition) {
  final dir = Directory.systemTemp.createTempSync('same_code');
  try {
    final f = File('${dir.path}/in.rs')..writeAsStringSync(src);
    // Through stdin, so rustfmt formats this file alone (not its `mod`s).
    final r = Process.runSync('sh', [
      '-c',
      'rustfmt --edition "\$1" --emit stdout < "\$2"',
      'sh',
      edition,
      f.path,
    ], stdoutEncoding: utf8);
    return r.exitCode == 0 ? r.stdout as String : null;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// The edition in the Cargo.toml nearest to [path] at [rev] (default 2021).
String _edition(String rev, String path) {
  var dir = path;
  while (dir.contains('/')) {
    dir = dir.substring(0, dir.lastIndexOf('/'));
    final r = Process.runSync('git', [
      'show',
      '$rev:$dir/Cargo.toml',
    ], stdoutEncoding: utf8);
    if (r.exitCode == 0) {
      final m = RegExp(
        r'^edition\s*=\s*"(\d+)"',
        multiLine: true,
      ).firstMatch(r.stdout as String);
      return m?.group(1) ?? '2021';
    }
  }
  return '2021';
}

String _short(String s) {
  final one = s.replaceAll('\n', r'\n');
  return one.length > 40 ? '${one.substring(0, 40)}…' : one;
}

String _show(String rev, String path) => _git(['show', '$rev:$path']);

String _git(List<String> args) {
  final r = Process.runSync('git', args, stdoutEncoding: utf8);
  if (r.exitCode != 0) {
    stderr.writeln('same_code: git ${args.join(' ')}: ${r.stderr}');
    exit(2);
  }
  return r.stdout as String;
}
