// Ported from Lua 5.2.3 ldebug.c, `luaO_chunkid` of lobject.c and
// `luaL_argerror`, `luaL_traceback` and `pushglobalfuncname` of lauxlib.c
// (MIT, see LICENSE-lua).

import 'opcodes.dart';
import 'proto.dart';
import 'state.dart';
import 'table.dart';
import 'value.dart';

/// The location of an operand without a register or upvalue in error
/// messages, such as a constant or a temporary.
const noLoc = -1 << 40;

const _idSize = 60;

/// `luaO_chunkid` with `LUA_IDSIZE` 60.
String chunkId(String source) {
  const rets = '...';
  if (source.startsWith('=')) {
    final s = source.substring(1);
    return s.length <= _idSize - 1 ? s : s.substring(0, _idSize - 1);
  }
  if (source.startsWith('@')) {
    final s = source.substring(1);
    if (s.length <= _idSize - 1) return s;
    final keep = _idSize - 1 - rets.length;
    return rets + s.substring(s.length - keep);
  }
  const pre = '[string "', pos = '"]';
  final avail = _idSize - (pre.length + rets.length + pos.length) - 1;
  final nl = source.indexOf('\n');
  if (source.length < avail && nl < 0) return '$pre$source$pos';
  var l = nl >= 0 ? nl : source.length;
  if (l > avail) l = avail;
  return '$pre${source.substring(0, l)}$rets$pos';
}

String _upvalName(LuaProto p, int uv) =>
    uv < p.upvalues.length ? (p.upvalues[uv].name ?? '?') : '?';

int _filterPc(int pc, int jmptarget) => pc < jmptarget ? -1 : pc;

/// `findsetreg`. Returns the last instruction before [lastpc] that changed
/// [reg].
int _findSetReg(LuaProto p, int lastpc, int reg) {
  var setreg = -1;
  var jmptarget = 0;
  for (var pc = 0; pc < lastpc; pc++) {
    final i = p.code[pc];
    final op = opOf(i);
    final a = argA(i);
    switch (op) {
      case Op.LOADNIL:
        final b = argB(i);
        if (a <= reg && reg <= a + b) setreg = _filterPc(pc, jmptarget);
      case Op.TFORCALL:
        if (reg >= a + 2) setreg = _filterPc(pc, jmptarget);
      case Op.CALL:
      case Op.TAILCALL:
        if (reg >= a) setreg = _filterPc(pc, jmptarget);
      case Op.JMP:
        final dest = pc + 1 + argSBx(i);
        if (pc < dest && dest <= lastpc && dest > jmptarget) jmptarget = dest;
      case Op.TEST:
        if (reg == a) setreg = _filterPc(pc, jmptarget);
      default:
        if (opModes[op].$2 && reg == a) setreg = _filterPc(pc, jmptarget);
    }
  }
  return setreg;
}

String _kname(LuaProto p, int pc, int c) {
  if (isK(c)) {
    final kv = p.constants[indexK(c)];
    if (kv is String) return kv;
  } else {
    final r = getObjName(p, pc, c);
    if (r != null && r.$1 == 'constant') return r.$2;
  }
  return '?';
}

/// `getobjname`. Returns the kind and the name of register [reg] at
/// [lastpc], or null.
(String, String)? getObjName(LuaProto p, int lastpc, int reg) {
  final local = p.localName(reg + 1, lastpc);
  if (local != null) return ('local', local);
  final pc = _findSetReg(p, lastpc, reg);
  if (pc == -1) return null;
  final i = p.code[pc];
  switch (opOf(i)) {
    case Op.MOVE:
      final b = argB(i);
      if (b < argA(i)) return getObjName(p, pc, b);
    case Op.GETTABUP:
    case Op.GETTABLE:
      final t = argB(i);
      final vn = opOf(i) == Op.GETTABLE
          ? p.localName(t + 1, pc)
          : _upvalName(p, t);
      final name = _kname(p, pc, argC(i));
      return (vn == '_ENV' ? 'global' : 'field', name);
    case Op.GETUPVAL:
      return ('upvalue', _upvalName(p, argB(i)));
    case Op.LOADK:
    case Op.LOADKX:
      final b = opOf(i) == Op.LOADK ? argBx(i) : argAx(p.code[pc + 1]);
      final kv = p.constants[b];
      if (kv is String) return ('constant', kv);
    case Op.SELF:
      return ('method', _kname(p, pc, argC(i)));
  }
  return null;
}

const _tmNames = [
  '__index', '__newindex', '__gc', '__mode', '__len', '__eq', '__add',
  '__sub', '__mul', '__div', '__mod', '__pow', '__unm', '__lt', '__le',
  '__concat', '__call', //
];

/// `getfuncname`. Returns the namewhat and the name of the function that the
/// current instruction of the Lua frame [ci] calls.
(String, String)? _getFuncName(CallInfo ci) {
  final p = ci.cl!.p;
  final pc = ci.savedPc - 1;
  final i = p.code[pc];
  int tm;
  switch (opOf(i)) {
    case Op.CALL:
    case Op.TAILCALL:
      return getObjName(p, pc, argA(i));
    case Op.TFORCALL:
      return ('for iterator', 'for iterator');
    case Op.SELF:
    case Op.GETTABUP:
    case Op.GETTABLE:
      tm = 0;
    case Op.SETTABUP:
    case Op.SETTABLE:
      tm = 1;
    case Op.EQ:
      tm = 5;
    case Op.ADD:
      tm = 6;
    case Op.SUB:
      tm = 7;
    case Op.MUL:
      tm = 8;
    case Op.DIV:
      tm = 9;
    case Op.MOD:
      tm = 10;
    case Op.POW:
      tm = 11;
    case Op.UNM:
      tm = 12;
    case Op.LEN:
      tm = 4;
    case Op.LT:
      tm = 13;
    case Op.LE:
      tm = 14;
    case Op.CONCAT:
      tm = 15;
    default:
      return null;
  }
  return ('metamethod', _tmNames[tm]);
}

/// The `"n"` part of `lua_getinfo` for the frame at index [ciIdx]. Returns
/// the namewhat and the name from the calling Lua instruction, or null for a
/// tail call.
(String, String)? frameName(LuaThread L, int ciIdx) {
  if (ciIdx <= 0) return null;
  final ci = L.cis[ciIdx];
  if (ci.callStatus & cistTail != 0) return null;
  final prev = L.cis[ciIdx - 1];
  if (!prev.isLua) return null;
  return _getFuncName(prev);
}

/// `lua_Debug` for one frame or function.
class LuaDebugInfo {
  String source = '=?';
  String shortSrc = '?';
  String what = 'C';
  int currentLine = -1;
  int lineDefined = -1;
  int lastLineDefined = -1;
  String? name;
  String nameWhat = '';
  bool isTailCall = false;
  int nups = 0;
  int nparams = 0;
  bool isVararg = true;
  Object? func;
  int ciIndex = -1;
}

void _funcInfo(LuaDebugInfo ar, Object? f) {
  ar.func = f;
  if (f is LuaClosure) {
    final p = f.p;
    ar.source = p.source ?? '=?';
    ar.lineDefined = p.lineDefined;
    ar.lastLineDefined = p.lastLineDefined;
    ar.what = p.lineDefined == 0 ? 'main' : 'Lua';
    ar.nups = f.upvals.length;
    ar.nparams = p.numParams;
    ar.isVararg = p.isVararg;
  } else {
    ar.source = '=[C]';
    ar.lineDefined = -1;
    ar.lastLineDefined = -1;
    ar.what = 'C';
    ar.nups = 0;
    ar.nparams = 0;
    ar.isVararg = true;
  }
  ar.shortSrc = chunkId(ar.source);
}

/// `lua_getstack` and `lua_getinfo(L, "Slnutf")` for stack [level], or
/// null.
LuaDebugInfo? getStackInfo(LuaThread L, int level) {
  final idx = L.ciIndex - level;
  if (level < 0 || idx <= 0) return null;
  final ci = L.cis[idx];
  final ar = LuaDebugInfo()..ciIndex = idx;
  _funcInfo(ar, L.stack[ci.func]);
  if (ci.isLua) ar.currentLine = ci.cl!.p.lineAt(ci.savedPc - 1);
  ar.isTailCall = ci.callStatus & cistTail != 0;
  final n = frameName(L, idx);
  if (n != null) {
    ar.nameWhat = n.$1;
    ar.name = n.$2;
  }
  return ar;
}

/// `lua_getinfo(L, ">S...")` for a function value.
LuaDebugInfo getFunctionInfo(Object? f) {
  final ar = LuaDebugInfo();
  _funcInfo(ar, f);
  return ar;
}

/// `varinfo`, the description of the operand at [loc]. [loc] is a register
/// index of 0 or more, the complement of an upvalue index or [noLoc].
/// Returns null when nothing is known.
(String, String)? varInfo(LuaThread L, int loc) {
  final ci = L.ci;
  if (!ci.isLua || loc == noLoc) return null;
  final p = ci.cl!.p;
  if (loc < 0) return ('upvalue', _upvalName(p, ~loc));
  if (loc >= ci.base && loc < ci.top) {
    return getObjName(p, ci.savedPc - 1, loc - ci.base);
  }
  return null;
}

/// `luaG_typeerror`.
Never typeError(LuaThread L, Object? o, String op, int loc) {
  final t = luaTypeName(o);
  final v = varInfo(L, loc);
  if (v != null) L.runError("attempt to $op ${v.$1} '${v.$2}' (a $t value)");
  L.runError('attempt to $op a $t value');
}

/// `luaG_ordererror`.
Never orderError(LuaThread L, Object? p1, Object? p2) {
  final t1 = luaTypeName(p1), t2 = luaTypeName(p2);
  if (t1 == t2) L.runError('attempt to compare two $t1 values');
  L.runError('attempt to compare $t1 with $t2');
}

/// `findfield`. Returns the path "key" or "key.key" in [t] whose value is
/// [obj], over string keys in `next` order and [level] tables deep.
String? _findField(Object? t, Object? obj, int level) {
  if (level == 0 || t is! LuaTable) return null;
  Object? k;
  while (true) {
    final r = t.next(k);
    if (r == null) return null;
    k = r.$1;
    if (k is String) {
      if (luaRawEquals(r.$2, obj)) return k;
      final sub = _findField(r.$2, obj, level - 1);
      if (sub != null) return '$k.$sub';
    }
  }
}

/// `pushglobalfuncname`.
String? globalFuncName(LuaThread L, Object? f) =>
    _findField(L.vm.globals, f, 2);

/// `luaL_argerror`.
Never argErrorImpl(LuaThread L, int narg, String extramsg) {
  if (L.ciIndex <= 0) L.luaError('bad argument #$narg ($extramsg)');
  final n = frameName(L, L.ciIndex);
  var name = n?.$2;
  if (n?.$1 == 'method') {
    narg--;
    if (narg == 0) L.luaError("calling '$name' on bad self ($extramsg)");
  }
  name ??= globalFuncName(L, L.stack[L.ci.func]) ?? '?';
  L.luaError("bad argument #$narg to '$name' ($extramsg)");
}

const _levels1 = 12, _levels2 = 10;

int _countLevels(LuaThread L) => L.ciIndex;

/// `luaL_traceback` of [L] from [level], after [msg].
String traceback(LuaThread L, String? msg, int level) {
  final sb = StringBuffer();
  if (msg != null) sb.write('$msg\n');
  sb.write('stack traceback:');
  final numLevels = _countLevels(L);
  final mark = numLevels > _levels1 + _levels2 ? _levels1 : 0;
  while (true) {
    final ar = getStackInfo(L, level++);
    if (ar == null) break;
    if (level == mark) {
      sb.write('\n\t...');
      level = numLevels - _levels2;
      continue;
    }
    sb.write('\n\t${ar.shortSrc}:');
    if (ar.currentLine > 0) sb.write('${ar.currentLine}:');
    sb.write(' in ');
    if (ar.nameWhat.isNotEmpty) {
      sb.write("function '${ar.name}'");
    } else if (ar.what == 'main') {
      sb.write('main chunk');
    } else if (ar.what == 'C') {
      final g = globalFuncName(L, ar.func);
      sb.write(g != null ? "function '$g'" : '?');
    } else {
      sb.write('function <${ar.shortSrc}:${ar.lineDefined}>');
    }
    if (ar.isTailCall) sb.write('\n\t(...tail calls...)');
  }
  return sb.toString();
}
