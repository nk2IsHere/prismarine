// A small lexer for the lint: it splits source into code tokens, string
// literals and comments, with line numbers.
//
// Dart, Rust and C-like files (GLSL, .fmat, C headers) are lexed exactly
// enough that dropping the comments and whitespace leaves the tokens the
// compiler sees, with operators grouped as each language groups them
// (see [_dartOperators]); same_code relies on that. The other languages
// (shell, Python, Lua, cdb, gdb, PowerShell) only have their comments found,
// line by line.

part 'line_comments.dart';

enum Lang { dart, rust, cLike, hash, lua, cdb, ps1 }

enum TokKind { word, number, punct, string, comment }

class Tok {
  Tok(this.kind, this.text, this.line, this.endLine);
  final TokKind kind;
  final String text;

  /// 1-based first and last line.
  final int line;
  final int endLine;

  bool get isCode => kind != TokKind.comment;

  @override
  String toString() => '$line:${kind.name}:$text';
}

/// The language of [path] by extension, or null for files the lint skips.
Lang? langOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  switch (path.substring(dot + 1)) {
    case 'dart':
      return Lang.dart;
    case 'rs':
      return Lang.rust;
    case 'frag' || 'vert' || 'glsl' || 'fmat' || 'c' || 'h' || 'cc' || 'cpp':
      return Lang.cLike;
    case 'sh' || 'py' || 'gdb' || 'toml' || 'cmake':
      return Lang.hash;
    case 'lua':
      return Lang.lua;
    case 'cdb':
      return Lang.cdb;
    case 'ps1':
      return Lang.ps1;
  }
  return null;
}

/// Whether [lang] is lexed exactly (code tokens are trustworthy).
bool isExact(Lang lang) =>
    lang == Lang.dart || lang == Lang.rust || lang == Lang.cLike;

List<Tok> lex(String src, Lang lang) => switch (lang) {
  Lang.dart || Lang.rust || Lang.cLike => _Lexer(src, lang).run(),
  Lang.hash || Lang.lua || Lang.cdb || Lang.ps1 => lineComments(src, lang),
};

// Multi-character operators, longest first. Both sides of a same_code
// comparison use the same table, so a missing entry only makes the
// comparison stricter, never looser.
const _dartOperators = [
  '>>>=',
  '...?',
  '<<=',
  '>>=',
  '>>>',
  '??=',
  '~/=',
  '&&=',
  '||=',
  '...',
  '?..',
  '==',
  '!=',
  '<=',
  '>=',
  '&&',
  '||',
  '++',
  '--',
  '+=',
  '-=',
  '*=',
  '/=',
  '%=',
  '&=',
  '|=',
  '^=',
  '~/',
  '=>',
  '..',
  '?.',
  '??',
  '<<',
  '>>',
];
const _rustOperators = [
  '<<=',
  '>>=',
  '...',
  '..=',
  '==',
  '!=',
  '<=',
  '>=',
  '&&',
  '||',
  '+=',
  '-=',
  '*=',
  '/=',
  '%=',
  '&=',
  '|=',
  '^=',
  '=>',
  '->',
  '::',
  '..',
  '<<',
  '>>',
];
const _cOperators = [
  '<<=',
  '>>=',
  '==',
  '!=',
  '<=',
  '>=',
  '&&',
  '||',
  '++',
  '--',
  '+=',
  '-=',
  '*=',
  '/=',
  '%=',
  '&=',
  '|=',
  '^=',
  '->',
  '##',
  '<<',
  '>>',
];

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || // A-Z
    (c >= 0x61 && c <= 0x7a) || // a-z
    c == 0x5f || // _
    c >= 0x80;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdent(int c) => _isIdentStart(c) || _isDigit(c);

class _Lexer {
  _Lexer(this.s, this.lang);
  final String s;
  final Lang lang;
  int i = 0;
  int line = 1;
  final out = <Tok>[];

  int _at(int k) => k < s.length ? s.codeUnitAt(k) : -1;

  bool _starts(String t, [int? at]) => s.startsWith(t, at ?? i);

  void _advanceTo(int end) {
    for (var k = i; k < end && k < s.length; k++) {
      if (s.codeUnitAt(k) == 0x0a) line++;
    }
    i = end;
  }

  List<Tok> run() {
    _scan(stopAtBrace: false);
    return out;
  }

  // Scans tokens until the end, or (inside a Dart interpolation) until the
  // unmatched closing brace, which is consumed but not emitted.
  void _scan({required bool stopAtBrace}) {
    var depth = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x0a) {
        line++;
        i++;
        continue;
      }
      if (c == 0x20 || c == 0x09 || c == 0x0d || c == 0x0c) {
        i++;
        continue;
      }
      if (_starts('//')) {
        final start = i;
        var end = s.indexOf('\n', i);
        if (end < 0) end = s.length;
        out.add(Tok(TokKind.comment, s.substring(start, end), line, line));
        i = end;
        continue;
      }
      if (_starts('/*')) {
        _blockComment();
        continue;
      }
      if (stopAtBrace) {
        if (c == 0x7b) depth++;
        if (c == 0x7d) {
          if (depth == 0) {
            i++;
            return;
          }
          depth--;
        }
      }
      if (_stringStart()) continue;
      if (_isIdentStart(c) || (lang == Lang.dart && c == 0x24)) {
        final start = i;
        while (i < s.length &&
            (_isIdent(s.codeUnitAt(i)) ||
                (lang == Lang.dart && s.codeUnitAt(i) == 0x24))) {
          i++;
        }
        out.add(Tok(TokKind.word, s.substring(start, i), line, line));
        continue;
      }
      // A leading `.5` is a number in Dart and C; Rust's `x.0` is a field.
      if (_isDigit(c) ||
          (lang != Lang.rust && c == 0x2e && _isDigit(_at(i + 1)))) {
        _number();
        continue;
      }
      if (lang == Lang.rust && c == 0x27 && _rustCharOrLifetime()) continue;
      var op = String.fromCharCode(c);
      final ops = switch (lang) {
        Lang.dart => _dartOperators,
        Lang.rust => _rustOperators,
        _ => _cOperators,
      };
      for (final o in ops) {
        if (_starts(o)) {
          op = o;
          break;
        }
      }
      out.add(Tok(TokKind.punct, op, line, line));
      i += op.length;
    }
  }

  void _blockComment() {
    final start = i;
    final startLine = line;
    var depth = 0;
    final nests = lang != Lang.cLike;
    while (i < s.length) {
      if (_starts('/*')) {
        depth++;
        i += 2;
        if (!nests && depth > 1) depth = 1;
        continue;
      }
      if (_starts('*/')) {
        depth--;
        i += 2;
        if (depth == 0) break;
        continue;
      }
      if (s.codeUnitAt(i) == 0x0a) line++;
      i++;
    }
    out.add(Tok(TokKind.comment, s.substring(start, i), startLine, line));
  }

  void _number() {
    final start = i;
    if (_starts('0x') || _starts('0X') || _starts('0b') || _starts('0o')) {
      i += 2;
      while (i < s.length && (_isIdent(s.codeUnitAt(i)))) {
        i++;
      }
    } else {
      bool digitOrSep(int c) => _isDigit(c) || c == 0x5f;
      while (i < s.length && digitOrSep(s.codeUnitAt(i))) {
        i++;
      }
      if (_at(i) == 0x2e && _isDigit(_at(i + 1))) {
        i++;
        while (i < s.length && digitOrSep(s.codeUnitAt(i))) {
          i++;
        }
      } else if (lang == Lang.rust &&
          _at(i) == 0x2e &&
          !_isIdentStart(_at(i + 1)) &&
          _at(i + 1) != 0x2e) {
        i++; // `1.` is a float literal in Rust
      }
      final e = _at(i);
      if (e == 0x65 || e == 0x45) {
        final n = _at(i + 1);
        if (_isDigit(n) || ((n == 0x2b || n == 0x2d) && _isDigit(_at(i + 2)))) {
          i += 2;
          while (i < s.length && digitOrSep(s.codeUnitAt(i))) {
            i++;
          }
        }
      }
      // Suffixes (Rust `u32`, `f32`; C `f`, `u`).
      while (i < s.length && _isIdent(s.codeUnitAt(i))) {
        i++;
      }
    }
    out.add(Tok(TokKind.number, s.substring(start, i), line, line));
  }

  // Rust: a char literal ('a', '\n', '\u{1F600}') or a lifetime ('a).
  bool _rustCharOrLifetime() {
    final start = i;
    if (_at(i + 1) == 0x5c) {
      var k = i + 3; // past the backslash and the escaped character
      while (k < s.length &&
          s.codeUnitAt(k) != 0x27 &&
          s.codeUnitAt(k) != 0x0a) {
        k++;
      }
      i = k + 1;
      out.add(Tok(TokKind.string, s.substring(start, i), line, line));
      return true;
    }
    // One code point (possibly a surrogate pair), then a quote.
    final next = _at(i + 1);
    final width = (next >= 0xd800 && next <= 0xdbff) ? 2 : 1;
    if (_at(i + 1 + width) == 0x27) {
      i += 2 + width;
      out.add(Tok(TokKind.string, s.substring(start, i), line, line));
      return true;
    }
    // A lifetime: emit it as one word.
    i++;
    while (i < s.length && _isIdent(s.codeUnitAt(i))) {
      i++;
    }
    out.add(Tok(TokKind.word, s.substring(start, i), line, line));
    return true;
  }

  // Scans a string literal if one starts here; returns whether it did.
  bool _stringStart() {
    switch (lang) {
      case Lang.dart:
        return _dartString();
      case Lang.rust:
        return _rustString();
      default:
        return _cString();
    }
  }

  bool _cString() {
    final c = s.codeUnitAt(i);
    if (c != 0x22 && c != 0x27) return false;
    final start = i;
    final startLine = line;
    i++;
    while (i < s.length && s.codeUnitAt(i) != c) {
      if (s.codeUnitAt(i) == 0x5c) i++;
      if (i < s.length && s.codeUnitAt(i) == 0x0a) line++;
      i++;
    }
    i++;
    out.add(
      Tok(
        TokKind.string,
        s.substring(start, i.clamp(0, s.length)),
        startLine,
        line,
      ),
    );
    return true;
  }

  bool _rustString() {
    final start = i;
    var k = i;
    // Prefixes: b, c, r, br, cr.
    if (_at(k) == 0x62 || _at(k) == 0x63) k++;
    var raw = false;
    if (_at(k) == 0x72) {
      raw = true;
      k++;
    }
    var hashes = 0;
    if (raw) {
      while (_at(k) == 0x23) {
        hashes++;
        k++;
      }
    }
    if (_at(k) == 0x27 && k == start + 1 && _at(start) == 0x62) {
      // b'x' byte literal
      i = k;
      final ok = _rustCharOrLifetime();
      final t = out.removeLast();
      out.add(Tok(TokKind.string, 'b${t.text}', t.line, t.endLine));
      return ok;
    }
    if (_at(k) != 0x22) return false;
    // A prefix must start the token (not the tail of an identifier).
    if (k != start && start > 0 && _isIdent(s.codeUnitAt(start - 1))) {
      return false;
    }
    final startLine = line;
    i = k + 1;
    if (raw) {
      final close = '"${'#' * hashes}';
      final end = s.indexOf(close, i);
      _advanceTo(end < 0 ? s.length : end + close.length);
    } else {
      while (i < s.length && s.codeUnitAt(i) != 0x22) {
        if (s.codeUnitAt(i) == 0x5c) i++;
        if (i < s.length && s.codeUnitAt(i) == 0x0a) line++;
        i++;
      }
      i++;
    }
    out.add(
      Tok(
        TokKind.string,
        s.substring(start, i.clamp(0, s.length)),
        startLine,
        line,
      ),
    );
    return true;
  }

  bool _dartString() {
    final start = i;
    var k = i;
    var raw = false;
    if (_at(k) == 0x72 && (_at(k + 1) == 0x27 || _at(k + 1) == 0x22)) {
      if (start > 0 && _isIdent(s.codeUnitAt(start - 1))) return false;
      raw = true;
      k++;
    }
    final q = _at(k);
    if (q != 0x27 && q != 0x22) return false;
    final quote = String.fromCharCode(q);
    final triple = _starts('$quote$quote$quote', k);
    final close = triple ? '$quote$quote$quote' : quote;
    final startLine = line;
    i = k + close.length;
    while (i < s.length) {
      if (_starts(close)) {
        i += close.length;
        break;
      }
      final c = s.codeUnitAt(i);
      if (!triple && c == 0x0a) break; // unterminated; let the caller go on
      if (!raw && c == 0x5c) {
        if (_at(i + 1) == 0x0a) line++;
        i += 2;
        continue;
      }
      if (!raw && c == 0x24 && _at(i + 1) == 0x7b) {
        // ${ expression }: lex it to find its end (strings and braces nest),
        // then drop the inner tokens: the literal is kept verbatim.
        final mark = out.length;
        i += 2;
        _scan(stopAtBrace: true);
        out.removeRange(mark, out.length);
        continue;
      }
      if (c == 0x0a) line++;
      i++;
    }
    out.add(
      Tok(
        TokKind.string,
        s.substring(start, i.clamp(0, s.length)),
        startLine,
        line,
      ),
    );
    return true;
  }
}
