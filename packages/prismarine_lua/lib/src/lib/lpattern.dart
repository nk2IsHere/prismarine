// Ported from the pattern matching of Lua 5.2.3 lstrlib.c (MIT, see
// LICENSE-lua). Strings are byte strings. A position past the end reads as
// NUL, as in C.

import 'dart:typed_data';

import '../state.dart';

const _maxCaptures = 32;
const _capUnfinished = -1;
const _capPosition = -2;
const _maxCCalls = 200;
const _lEsc = 0x25; // '%'
const specials = r'^$*+?.([%-';

// The ctype functions of the C locale on bytes.
bool cIsAlpha(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
bool cIsDigit(int c) => c >= 0x30 && c <= 0x39;
bool cIsLower(int c) => c >= 0x61 && c <= 0x7A;
bool cIsUpper(int c) => c >= 0x41 && c <= 0x5A;
bool cIsAlnum(int c) => cIsAlpha(c) || cIsDigit(c);
bool cIsCntrl(int c) => c < 0x20 || c == 0x7F;
bool cIsSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D);
bool cIsGraph(int c) => c >= 0x21 && c <= 0x7E;
bool cIsPunct(int c) => cIsGraph(c) && !cIsAlnum(c);
bool cIsXDigit(int c) =>
    cIsDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
int cToLower(int c) => cIsUpper(c) ? c + 0x20 : c;
int cToUpper(int c) => cIsLower(c) ? c - 0x20 : c;

class MatchState {
  MatchState(this.L, this.src, this.pat);
  final LuaThread L;
  final String src;
  final String pat;
  int matchDepth = _maxCCalls;
  int level = 0;
  // Made as typed lists when a pattern first opens a capture. Most patterns
  // have none.
  late final List<int> capInit = Int32List(_maxCaptures);
  late final List<int> capLen = Int32List(_maxCaptures);

  int get srcEnd => src.length;
  int get pEnd => pat.length;
  int s(int i) => i < src.length ? src.codeUnitAt(i) : 0;
  int p(int i) => i < pat.length ? pat.codeUnitAt(i) : 0;

  int _checkCapture(int l) {
    l -= 0x31;
    if (l < 0 || l >= level || capLen[l] == _capUnfinished) {
      L.luaError('invalid capture index %${l + 1}');
    }
    return l;
  }

  int _captureToClose() {
    var lv = level;
    for (lv--; lv >= 0; lv--) {
      if (capLen[lv] == _capUnfinished) return lv;
    }
    L.luaError('invalid pattern capture');
  }

  int _classEnd(int pi) {
    final c = p(pi++);
    if (c == _lEsc) {
      if (pi == pEnd) L.luaError("malformed pattern (ends with '%')");
      return pi + 1;
    }
    if (c == 0x5B) {
      if (p(pi) == 0x5E) pi++;
      do {
        if (pi == pEnd) L.luaError("malformed pattern (missing ']')");
        if (p(pi++) == _lEsc && pi < pEnd) pi++;
      } while (p(pi) != 0x5D);
      return pi + 1;
    }
    return pi;
  }

  static bool matchClass(int c, int cl) {
    bool res;
    switch (cToLower(cl)) {
      case 0x61:
        res = cIsAlpha(c);
      case 0x63:
        res = cIsCntrl(c);
      case 0x64:
        res = cIsDigit(c);
      case 0x67:
        res = cIsGraph(c);
      case 0x6C:
        res = cIsLower(c);
      case 0x70:
        res = cIsPunct(c);
      case 0x73:
        res = cIsSpace(c);
      case 0x75:
        res = cIsUpper(c);
      case 0x77:
        res = cIsAlnum(c);
      case 0x78:
        res = cIsXDigit(c);
      case 0x7A:
        res = c == 0;
      default:
        return cl == c;
    }
    return cIsLower(cl) ? res : !res;
  }

  bool _matchBracketClass(int c, int pi, int ec) {
    var sig = true;
    if (p(pi + 1) == 0x5E) {
      sig = false;
      pi++;
    }
    while (++pi < ec) {
      if (p(pi) == _lEsc) {
        pi++;
        if (matchClass(c, p(pi))) return sig;
      } else if (p(pi + 1) == 0x2D && pi + 2 < ec) {
        pi += 2;
        if (p(pi - 2) <= c && c <= p(pi)) return sig;
      } else if (p(pi) == c) {
        return sig;
      }
    }
    return !sig;
  }

  bool _singleMatch(int si, int pi, int ep) {
    if (si >= srcEnd) return false;
    final c = s(si);
    switch (p(pi)) {
      case 0x2E:
        return true;
      case _lEsc:
        return matchClass(c, p(pi + 1));
      case 0x5B:
        return _matchBracketClass(c, pi, ep - 1);
      default:
        return p(pi) == c;
    }
  }

  int _matchBalance(int si, int pi) {
    if (pi >= pEnd - 1) {
      L.luaError("malformed pattern (missing arguments to '%b')");
    }
    if (s(si) != p(pi)) return -1;
    final b = p(pi), e = p(pi + 1);
    var cont = 1;
    while (++si < srcEnd) {
      final c = s(si);
      if (c == e) {
        if (--cont == 0) return si + 1;
      } else if (c == b) {
        cont++;
      }
    }
    return -1;
  }

  int _maxExpand(int si, int pi, int ep) {
    var i = 0;
    while (_singleMatch(si + i, pi, ep)) {
      i++;
    }
    while (i >= 0) {
      final res = match(si + i, ep + 1);
      if (res != -1) return res;
      i--;
    }
    return -1;
  }

  int _minExpand(int si, int pi, int ep) {
    for (;;) {
      final res = match(si, ep + 1);
      if (res != -1) return res;
      if (_singleMatch(si, pi, ep)) {
        si++;
      } else {
        return -1;
      }
    }
  }

  int _startCapture(int si, int pi, int what) {
    if (level >= _maxCaptures) L.luaError('too many captures');
    capInit[level] = si;
    capLen[level] = what;
    level++;
    final res = match(si, pi);
    if (res == -1) level--;
    return res;
  }

  int _endCapture(int si, int pi) {
    final l = _captureToClose();
    capLen[l] = si - capInit[l];
    final res = match(si, pi);
    if (res == -1) capLen[l] = _capUnfinished;
    return res;
  }

  int _matchCapture(int si, int l) {
    l = _checkCapture(l);
    final len = capLen[l];
    // A position capture has the length -2. As a size_t it does not fit, and
    // the back-reference does not match.
    if (len >= 0 &&
        srcEnd - si >= len &&
        src.substring(capInit[l], capInit[l] + len) ==
            src.substring(si, si + len)) {
      return si + len;
    }
    return -1;
  }

  /// `match`. Returns the end of the match of the pattern from [pi] at [si],
  /// or -1.
  int match(int si, int pi) {
    if (matchDepth-- == 0) L.luaError('pattern too complex');
    init:
    while (true) {
      if (pi != pEnd) {
        switch (p(pi)) {
          case 0x28: // '('
            if (p(pi + 1) == 0x29) {
              si = _startCapture(si, pi + 2, _capPosition);
            } else {
              si = _startCapture(si, pi + 1, _capUnfinished);
            }
            break init;
          case 0x29: // ')'
            si = _endCapture(si, pi + 1);
            break init;
          case 0x24: // '$'
            if (pi + 1 == pEnd) {
              si = si == srcEnd ? si : -1;
              break init;
            }
          case _lEsc:
            switch (p(pi + 1)) {
              case 0x62: // 'b'
                si = _matchBalance(si, pi + 2);
                if (si != -1) {
                  pi += 4;
                  continue init;
                }
                break init;
              case 0x66: // 'f'
                pi += 2;
                if (p(pi) != 0x5B) {
                  L.luaError("missing '[' after '%f' in pattern");
                }
                final ep = _classEnd(pi);
                final previous = si == 0 ? 0 : s(si - 1);
                if (!_matchBracketClass(previous, pi, ep - 1) &&
                    _matchBracketClass(s(si), pi, ep - 1)) {
                  pi = ep;
                  continue init;
                }
                si = -1;
                break init;
              case >= 0x30 && <= 0x39:
                si = _matchCapture(si, p(pi + 1));
                if (si != -1) {
                  pi += 2;
                  continue init;
                }
                break init;
            }
        }
        // A pattern class with an optional suffix.
        final ep = _classEnd(pi);
        final epc = p(ep);
        if (!_singleMatch(si, pi, ep)) {
          if (epc == 0x2A || epc == 0x3F || epc == 0x2D) {
            pi = ep + 1;
            continue init;
          }
          si = -1;
        } else {
          switch (epc) {
            case 0x3F: // '?'
              final res = match(si + 1, ep + 1);
              if (res != -1) {
                si = res;
              } else {
                pi = ep + 1;
                continue init;
              }
            case 0x2B: // '+'
              si = _maxExpand(si + 1, pi, ep);
            case 0x2A: // '*'
              si = _maxExpand(si, pi, ep);
            case 0x2D: // '-'
              si = _minExpand(si, pi, ep);
            default:
              si++;
              pi = ep;
              continue init;
          }
        }
      }
      break;
    }
    matchDepth++;
    return si;
  }

  /// `push_onecapture`. Returns the value of capture [i], or the whole match
  /// from [s0] to [e] when there are no captures.
  Object? capture(int i, int s0, int e) {
    if (i >= level) {
      if (i == 0) return src.substring(s0, e);
      L.luaError('invalid capture index');
    }
    final l = capLen[i];
    if (l == _capUnfinished) L.luaError('unfinished capture');
    if (l == _capPosition) return (capInit[i] + 1).toDouble();
    return src.substring(capInit[i], capInit[i] + l);
  }

  /// `push_captures`. Pushes the captures or the whole match and returns
  /// their count. A negative [s0] pushes no whole match, as `find` needs.
  int pushCaptures(int s0, int e) {
    final n = (level == 0 && s0 >= 0) ? 1 : level;
    L.checkStack(n);
    for (var i = 0; i < n; i++) {
      L.push(capture(i, s0, e));
    }
    return n;
  }
}
