// The generic code_shape rules for history in a comment and for a long
// comment block or function. A repository adds rule sets from
// src/rule_sets.dart in its lint config.
import 'lexer.dart';
import 'rule_sets.dart';

const hardLimit = 1000;
const softLimit = 500;
const commentBlockLimit = 12;
const headerBlockLimit = 20;
const functionLimit = 150;

class Hit {
  Hit(this.check, this.rule, this.line, this.text);

  /// The ratcheted category, history or long-comment or the check of a rule
  /// set.
  final String check;

  /// The rule within it (for the listing).
  final String rule;
  final int line;
  final String text;
}

// ---------------------------------------------------------------------------
// History in comments
//
// Comments carry no history. A history hit is a date, a run id, an agent or
// branch word, a commit hash, a "the port used to" narrative, a pointer into
// plans, reports, memory files or research/ or "the user" for the developer.
// The lint config of a repository lists its agent words and extra pointer
// patterns under code_shape.history. Agent words that are ordinary English
// words are left out of that list.

/// The history rules with the agent and branch words [names] and the extra
/// pointer patterns [pointers].
class HistoryRules {
  HistoryRules({
    List<String> names = const [],
    List<String> pointers = const [],
  }) : _rules = {
         'run-id': RegExp(r'\b20\d{6}-\d{6}\b'),
         'date': RegExp(r'\b20[12]\d-[01]\d(-[0-3]\d)?\b'),
         'branch': RegExp(r'\bfix-(?!up\b)[a-z]+\d*\b'),
         if (names.isNotEmpty) 'agent': RegExp('\\b(${names.join('|')})\\b'),
         'narrative': RegExp(
           r'\bthe port (had|used to|was|did|drew|played|kept|left|sent|lost)\b'
           r'|\bpreviously\b|\b(we|it|this|they|that|which) used to\b'
           r'|\bfixed (in|by)\b|\bwas (wrong|broken|buggy)\b'
           r'|\(was\b|\b(before|after) the fix\b|\bregress(ed|ion from)\b',
           caseSensitive: false,
         ),
         'pointer': RegExp(
           [
             r'\bREPORT\b|REPORT-|docs/memory/|docs/plans/|\bresearch/',
             ...pointers,
           ].join('|'),
         ),
         // Terms such as "the user store" do not mean the developer.
         'user': RegExp(
           r'\bthe user\b(?![- ](store|location|bundle|profile|prefs)|-)'
           r"|\buser's\b",
         ),
       };

  final Map<String, RegExp> _rules;

  /// Returns the history rule that comment line [text] breaks, or null.
  String? rule(String text) {
    for (final e in _rules.entries) {
      if (e.value.hasMatch(text)) return e.key;
    }
    return null;
  }
}

// Commit hashes: 7 to 12 hex digits with a letter and a digit, counted only
// when git knows them as commits (see [hashCandidates]), so CRCs and type
// version hashes in comments are left alone.
final _hashCandidate = RegExp(
  r'(?<![0-9A-Za-z_#])(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,12}(?![0-9A-Za-z_])',
);

/// Hash-shaped words in comment line [text].
Iterable<String> hashCandidates(String text) =>
    _hashCandidate.allMatches(text).map((m) => m.group(0)!);

// ---------------------------------------------------------------------------

/// Returns the history hits and the comment and string hits of [sets] in
/// [toks].
List<Hit> commentHits(
  List<Tok> toks,
  Lang lang,
  HistoryRules history, [
  List<RuleSet> sets = const [],
]) {
  final hits = <Hit>[];
  for (final t in toks) {
    if (t.kind == TokKind.comment) {
      final lines = t.text.split('\n');
      for (var k = 0; k < lines.length; k++) {
        final l = lines[k];
        for (final s in sets) {
          final e = s.commentRule(l);
          if (e != null) hits.add(Hit(s.check, e, t.line + k, l.trim()));
        }
        final h = history.rule(l);
        if (h != null) hits.add(Hit('history', h, t.line + k, l.trim()));
      }
    } else if (t.kind == TokKind.string && isExact(lang)) {
      for (final s in sets) {
        final e = s.stringRule(t.text);
        if (e != null) {
          hits.add(
            Hit(s.check, 'string-$e', t.line, t.text.split('\n').first.trim()),
          );
        }
      }
    }
  }
  return hits;
}

/// Runs of consecutive comment lines longer than the limit (the file's
/// leading header has the larger limit).
List<Hit> longCommentHits(List<Tok> toks) {
  // Lines that hold code, and lines that hold comments.
  final code = <int>{};
  final comment = <int>{};
  for (final t in toks) {
    for (var n = t.line; n <= t.endLine; n++) {
      (t.isCode ? code : comment).add(n);
    }
  }
  final firstCode = code.isEmpty
      ? 1 << 30
      : code.reduce((a, b) => a < b ? a : b);
  final lines = comment.difference(code).toList()..sort();
  final hits = <Hit>[];
  var start = 0;
  for (var k = 1; k <= lines.length; k++) {
    if (k == lines.length || lines[k] != lines[k - 1] + 1) {
      final first = lines[start], last = lines[k - 1];
      final len = last - first + 1;
      final header = last < firstCode;
      final limit = header ? headerBlockLimit : commentBlockLimit;
      if (len > limit) {
        hits.add(
          Hit(
            'long-comment',
            header ? 'header' : 'block',
            first,
            '$len comment lines (limit $limit)',
          ),
        );
      }
      start = k;
    }
  }
  return hits;
}

class FunctionSpan {
  FunctionSpan(this.name, this.start, this.end);
  final String name;
  final int start, end;
  int get lines => end - start + 1;
}

/// Function bodies longer than [functionLimit] lines (an approximation by
/// brace matching over the code tokens; warnings only).
List<FunctionSpan> longFunctions(List<Tok> toks, Lang lang) {
  final code = toks.where((t) => t.isCode).toList();
  final spans = lang == Lang.rust
      ? _rustFunctions(code)
      : lang == Lang.dart
      ? _dartFunctions(code)
      : const <FunctionSpan>[];
  return spans.where((f) => f.lines > functionLimit).toList();
}

int _matchBrace(List<Tok> code, int open) {
  var depth = 0;
  for (var k = open; k < code.length; k++) {
    final t = code[k];
    if (t.kind != TokKind.punct) continue;
    if (t.text == '{') depth++;
    if (t.text == '}' && --depth == 0) return k;
  }
  return code.length - 1;
}

List<FunctionSpan> _rustFunctions(List<Tok> code) {
  final out = <FunctionSpan>[];
  for (var k = 0; k < code.length; k++) {
    if (code[k].kind != TokKind.word || code[k].text != 'fn') continue;
    if (k + 1 >= code.length || code[k + 1].kind != TokKind.word) continue;
    var paren = 0;
    for (var j = k + 2; j < code.length; j++) {
      final t = code[j];
      if (t.kind != TokKind.punct) continue;
      if (t.text == '(' || t.text == '[') paren++;
      if (t.text == ')' || t.text == ']') paren--;
      if (paren == 0 && t.text == ';') break;
      if (paren == 0 && t.text == '{') {
        out.add(
          FunctionSpan(
            code[k + 1].text,
            code[k].line,
            code[_matchBrace(code, j)].endLine,
          ),
        );
        break;
      }
    }
  }
  return out;
}

// Dart: at top level or in a class-like body, a `{` that opens neither a
// class-like body nor a variable's literal is a function body.
List<FunctionSpan> _dartFunctions(List<Tok> code) {
  final out = <FunctionSpan>[];
  const classy = {'class', 'mixin', 'enum', 'extension'};
  void scan(int from, int to) {
    var stmt = from;
    var paren = 0;
    for (var k = from; k < to; k++) {
      final t = code[k];
      if (t.kind != TokKind.punct) continue;
      if (t.text == '(' || t.text == '[') paren++;
      if (t.text == ')' || t.text == ']') paren--;
      if (paren != 0) continue;
      if (t.text == ';') {
        stmt = k + 1;
        continue;
      }
      if (t.text != '{') continue;
      final end = _matchBrace(code, k);
      final head = code.sublist(stmt, k);
      if (head.any((h) => h.kind == TokKind.word && classy.contains(h.text))) {
        scan(k + 1, end);
      } else {
        final firstParen = head.indexWhere((h) => h.text == '(');
        final firstEq = head.indexWhere((h) => h.text == '=');
        final isVar = firstEq >= 0 && (firstParen < 0 || firstEq < firstParen);
        if (!isVar && head.isNotEmpty) {
          final name = firstParen > 0
              ? head[firstParen - 1].text
              : head
                    .lastWhere(
                      (h) => h.kind == TokKind.word,
                      orElse: () => head.last,
                    )
                    .text;
          out.add(FunctionSpan(name, head.first.line, code[end].endLine));
        }
      }
      k = end;
      stmt = end + 1;
    }
  }

  scan(0, code.length);
  return out;
}
