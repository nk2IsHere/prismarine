part of 'lexer.dart';

// Line-based comment finding for the languages the lint does not lex fully.
List<Tok> lineComments(String src, Lang lang) {
  final out = <Tok>[];
  final lines = src.split('\n');
  var inBlock = false; // Lua --[[ ]] or PowerShell <# #>
  var blockClose = '';
  var blockStart = 0;
  final block = StringBuffer();
  for (var n = 0; n < lines.length; n++) {
    final l = lines[n];
    if (inBlock) {
      final end = l.indexOf(blockClose);
      block.writeln(end < 0 ? l : l.substring(0, end + blockClose.length));
      if (end >= 0) {
        inBlock = false;
        out.add(
          Tok(TokKind.comment, block.toString().trimRight(), blockStart, n + 1),
        );
        block.clear();
        final rest = l.substring(end + blockClose.length).trim();
        if (rest.isNotEmpty) out.add(Tok(TokKind.word, rest, n + 1, n + 1));
      }
      continue;
    }
    final at = _commentStart(l, lang, n == 0);
    if (at < 0) {
      if (l.trim().isNotEmpty) {
        out.add(Tok(TokKind.word, l.trim(), n + 1, n + 1));
      }
      continue;
    }
    final code = l.substring(0, at).trim();
    if (code.isNotEmpty) out.add(Tok(TokKind.word, code, n + 1, n + 1));
    final rest = l.substring(at);
    final open = lang == Lang.lua
        ? RegExp(r'^--\[(=*)\[').firstMatch(rest)
        : (lang == Lang.ps1 && rest.startsWith('<#')
              ? RegExp('^<#').firstMatch(rest)
              : null);
    if (open != null) {
      blockClose = lang == Lang.lua ? ']${open.group(1)}]' : '#>';
      final end = rest.indexOf(blockClose, open.end);
      if (end < 0) {
        inBlock = true;
        blockStart = n + 1;
        block.writeln(rest);
        continue;
      }
    }
    out.add(Tok(TokKind.comment, rest, n + 1, n + 1));
  }
  if (inBlock) {
    out.add(
      Tok(
        TokKind.comment,
        block.toString().trimRight(),
        blockStart,
        lines.length,
      ),
    );
  }
  return out;
}

// The column where a comment starts on [l], or -1. Quotes are tracked within
// the line only.
int _commentStart(String l, Lang lang, bool firstLine) {
  if (lang == Lang.cdb) {
    final t = l.trimLeft();
    if (t.startsWith('*')) return l.length - t.length;
  }
  if (lang == Lang.hash && firstLine && l.startsWith('#!')) return -1;
  int? quote;
  for (var k = 0; k < l.length; k++) {
    final c = l.codeUnitAt(k);
    if (quote != null) {
      if (c == 0x5c && quote == 0x22) {
        k++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == 0x22 || (c == 0x27 && lang != Lang.cdb)) {
      quote = c;
      continue;
    }
    switch (lang) {
      case Lang.hash || Lang.ps1:
        if (c == 0x3c &&
            lang == Lang.ps1 &&
            k + 1 < l.length &&
            l.codeUnitAt(k + 1) == 0x23) {
          return k;
        }
        if (c == 0x23) {
          final prev = k == 0 ? 0x20 : l.codeUnitAt(k - 1);
          if (prev == 0x20 || prev == 0x09 || prev == 0x3b) return k;
        }
      case Lang.lua:
        if (c == 0x2d && k + 1 < l.length && l.codeUnitAt(k + 1) == 0x2d) {
          return k;
        }
      case Lang.cdb:
        if (c == 0x24 && k + 1 < l.length && l.codeUnitAt(k + 1) == 0x24) {
          return k;
        }
      default:
        break;
    }
  }
  return -1;
}
