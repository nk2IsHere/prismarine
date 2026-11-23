// Ported from Lua 5.2.3 lvm.c and ltm.c (MIT, see LICENSE-lua). A call from
// Lua to Lua pushes a frame in the execute loop. CALL, TAILCALL, `__call` and
// the Lua iterators of TFORCALL do so. A metamethod runs as a nested call
// that cannot yield, where stock Lua can yield through `luaV_finishOp`.

import 'config.dart';
import 'debug.dart';
import 'number.dart';
import 'opcodes.dart';
import 'proto.dart';
import 'runtime.dart';
import 'state.dart';
import 'table.dart';
import 'value.dart';

const _maxTagLoop = 100;

/// Metamethod events in ltm.h order.
abstract final class TM {
  static const index = 0, newindex = 1, gc = 2, mode = 3, len = 4, eq = 5;
  static const add = 6, sub = 7, mul = 8, div = 9, mod = 10, pow = 11;
  static const unm = 12, lt = 13, le = 14, concat = 15, call = 16;
  static const names = [
    '__index', '__newindex', '__gc', '__mode', '__len', '__eq', '__add',
    '__sub', '__mul', '__div', '__mod', '__pow', '__unm', '__lt', '__le',
    '__concat', '__call', //
  ];
}

/// `fasttm` for the events up to `__eq`, with absence cached in the flags of
/// the metatable.
Object? fastTM(LuaTable? mt, int event) {
  if (mt == null || mt.flags & (1 << event) != 0) return null;
  final tm = mt.getStr(TM.names[event]);
  if (tm == null) {
    mt.flags |= 1 << event;
    return null;
  }
  return tm;
}

/// `luaT_gettmbyobj`.
Object? getTMByObj(LuaThread L, Object? o, int event) =>
    L.vm.metatableOf(o)?.getStr(TM.names[event]);

bool isFalse(Object? v) => v == null || v == false;

/// `luaV_tonumber` in [mode].
double? toNumberValue(Object? v, LuaNumberMode mode) {
  if (v is double) return v;
  if (v is String) return parseLuaNumber(v, mode);
  return null;
}

/// `callTM`. Calls [f] on the operands as a nested call that cannot yield.
/// Stores a result at stack index [res].
void callTM(
  LuaThread L,
  Object? f,
  Object? p1,
  Object? p2,
  Object? p3OrNull, {
  int res = -1,
}) {
  final hasRes = res >= 0;
  L.checkStack(4);
  final s = L.stack;
  s[L.top++] = f;
  s[L.top++] = p1;
  s[L.top++] = p2;
  if (!hasRes) s[L.top++] = p3OrNull;
  L.callAt(L.top - (hasRes ? 3 : 4), hasRes ? 1 : 0);
  if (hasRes) s[res] = s[--L.top];
}

bool _callBinTM(LuaThread L, Object? p1, Object? p2, int res, int event) {
  var tm = getTMByObj(L, p1, event);
  tm ??= getTMByObj(L, p2, event);
  if (tm == null) return false;
  callTM(L, tm, p1, p2, null, res: res);
  return true;
}

/// `luaV_gettable` into stack index [val]. [loc] is the location of [t] for
/// error messages, a register index of 0 or more, the complement of an
/// upvalue index or [noLoc].
void getTable(LuaThread L, Object? t, Object? key, int val, int loc) {
  for (var loop = 0; loop < _maxTagLoop; loop++) {
    Object? tm;
    if (t is LuaTable) {
      final res = t.get(key);
      if (res != null || (tm = fastTM(t.metatable, TM.index)) == null) {
        L.stack[val] = res;
        return;
      }
    } else {
      tm = getTMByObj(L, t, TM.index);
      if (tm == null) typeError(L, t, 'index', loc);
    }
    if (tm is LuaFunction) {
      callTM(L, tm, t, key, null, res: val);
      return;
    }
    t = tm;
    loc = noLoc;
  }
  L.runError('loop in gettable');
}

/// `luaV_settable`.
void setTable(LuaThread L, Object? t, Object? key, Object? val, int loc) {
  for (var loop = 0; loop < _maxTagLoop; loop++) {
    Object? tm;
    if (t is LuaTable) {
      if (t.metatable == null ||
          t.get(key) != null ||
          (tm = fastTM(t.metatable, TM.newindex)) == null) {
        if (key == null) L.runError('table index is nil');
        if (key is double && key.isNaN) L.runError('table index is NaN');
        t.set(key, val);
        return;
      }
    } else {
      tm = getTMByObj(L, t, TM.newindex);
      if (tm == null) typeError(L, t, 'index', loc);
    }
    if (tm is LuaFunction) {
      callTM(L, tm, t, key, val);
      return;
    }
    t = tm;
    loc = noLoc;
  }
  L.runError('loop in settable');
}

Object? _getEqualTM(LuaTable? mt1, LuaTable? mt2) {
  final tm1 = fastTM(mt1, TM.eq);
  if (tm1 == null) return null;
  if (identical(mt1, mt2)) return tm1;
  final tm2 = fastTM(mt2, TM.eq);
  if (tm2 == null) return null;
  return luaRawEquals(tm1, tm2) ? tm1 : null;
}

/// `equalobj`, which is `luaV_equalobj_` with the test of the types.
bool equalObj(LuaThread L, Object? a, Object? b) {
  if (a is double && b is double) return a == b;
  if (identical(a, b)) return true;
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  Object? tm;
  if (a is LuaTable && b is LuaTable) {
    tm = _getEqualTM(a.metatable, b.metatable);
  } else if (a is LuaUserdata && b is LuaUserdata) {
    tm = _getEqualTM(a.metatable, b.metatable);
  } else if (L.vm.mixedTypeEquality && luaTypeName(a) != luaTypeName(b)) {
    // Different types take the __eq of the first operand, else of the
    // second. Without one the values are not equal.
    tm =
        fastTM(L.vm.metatableOf(a), TM.eq) ??
        fastTM(L.vm.metatableOf(b), TM.eq);
  } else {
    return false;
  }
  if (tm == null) return false;
  callTM(L, tm, a, b, null, res: L.top);
  return !isFalse(L.stack[L.top]);
}

int _orderTM(LuaThread L, Object? p1, Object? p2, int event) {
  if (!_callBinTM(L, p1, p2, L.top, event)) return -1;
  return isFalse(L.stack[L.top]) ? 0 : 1;
}

/// `luaV_lessthan`.
bool lessThan(LuaThread L, Object? l, Object? r) {
  if (l is double && r is double) return l < r;
  if (l is String && r is String) return l.compareTo(r) < 0;
  final res = _orderTM(L, l, r, TM.lt);
  if (res < 0) orderError(L, l, r);
  return res != 0;
}

/// `luaV_lessequal`.
bool lessEqual(LuaThread L, Object? l, Object? r) {
  if (l is double && r is double) return l <= r;
  if (l is String && r is String) return l.compareTo(r) <= 0;
  var res = _orderTM(L, l, r, TM.le);
  if (res >= 0) return res != 0;
  res = _orderTM(L, r, l, TM.lt);
  if (res < 0) orderError(L, l, r);
  return res == 0;
}

/// `luaO_arith` on numbers in the float32 mode.
double arithOp(int event, double a, double b) => switch (event) {
  TM.add => f32(a + b),
  TM.sub => f32(a - b),
  TM.mul => f32(a * b),
  TM.div => f32(a / b),
  TM.mod => luaMod(a, b),
  TM.pow => luaPow(a, b),
  _ => -a, // unm
};

/// `luaO_arith` on numbers in the float64 mode.
double arithOp64(int event, double a, double b) => switch (event) {
  TM.add => f64(a + b),
  TM.sub => f64(a - b),
  TM.mul => f64(a * b),
  TM.div => f64(a / b),
  TM.mod => luaMod64(a, b),
  TM.pow => luaPow64(a, b),
  _ => -a, // unm
};

/// `luaO_arith` on numbers in the float32Single mode, with `powf` from
/// [rt].
double arithSingle(int event, double a, double b, LuaCRuntime rt) {
  final r = switch (event) {
    TM.add => a + b,
    TM.sub => a - b,
    TM.mul => a * b,
    TM.div => a / b,
    TM.mod => luaModSingle(a, b),
    TM.pow => rt.powf(a, b),
    _ => -a,
  };
  if (r.isNaN) return event >= TM.mod ? r : nanResult(a, b);
  return r32(r);
}

/// `luaO_arith` on numbers in the mode of [vm].
double arithVm(LuaVm vm, int event, double a, double b) =>
    switch (vm.numberMode) {
      LuaNumberMode.float32 => arithOp(event, a, b),
      LuaNumberMode.float64 => arithOp64(event, a, b),
      LuaNumberMode.float32Single => arithSingle(event, a, b, vm.runtime),
    };

/// `luaV_arith` on [rb] and [rc], with their locations [lb] and [lc] for
/// errors.
void arith(
  LuaThread L,
  int ra,
  Object? rb,
  Object? rc,
  int event,
  int lb,
  int lc,
) {
  final mode = L.vm.numberMode;
  final b = toNumberValue(rb, mode);
  final c = b == null ? null : toNumberValue(rc, mode);
  if (b != null && c != null) {
    L.stack[ra] = arithVm(L.vm, event, b, c);
  } else if (!_callBinTM(L, rb, rc, ra, event)) {
    // luaG_aritherror blames the operand that is not a number.
    if (toNumberValue(rb, mode) == null) {
      typeError(L, rb, 'perform arithmetic on', lb);
    }
    typeError(L, rc, 'perform arithmetic on', lc);
  }
}

/// `luaV_objlen`.
void objLen(LuaThread L, int ra, Object? rb, int loc) {
  Object? tm;
  if (rb is LuaTable) {
    tm = fastTM(rb.metatable, TM.len);
    if (tm == null) {
      L.stack[ra] = rb.length().toDouble();
      return;
    }
  } else if (rb is String) {
    L.stack[ra] = rb.length.toDouble();
    return;
  } else {
    tm = getTMByObj(L, rb, TM.len);
    if (tm == null) typeError(L, rb, 'get length of', loc);
  }
  callTM(L, tm, rb, rb, null, res: ra);
}

bool _toStr(LuaThread L, int idx) {
  final v = L.stack[idx];
  if (v is String) return true;
  if (v is double) {
    L.stack[idx] = L.vm.runtime.numberToString(v);
    return true;
  }
  return false;
}

/// `luaV_concat` of the [total] values below the top.
void concat(LuaThread L, int total) {
  final s = L.stack;
  do {
    final top = L.top;
    var n = 2;
    final a = s[top - 2];
    if (!(a is String || a is double) || !_toStr(L, top - 1)) {
      if (!_callBinTM(L, s[top - 2], s[top - 1], top - 2, TM.concat)) {
        // luaG_concaterror blames the operand that is not a string.
        final p1 = s[top - 2];
        if (p1 is String || p1 is double) {
          typeError(L, s[top - 1], 'concatenate', top - 1);
        }
        typeError(L, p1, 'concatenate', top - 2);
      }
    } else if ((s[top - 1] as String).isEmpty) {
      _toStr(L, top - 2);
    } else if (a is String && a.isEmpty) {
      s[top - 2] = s[top - 1];
    } else {
      var i = 1;
      while (i < total && _toStr(L, top - i - 1)) {
        i++;
      }
      n = i;
      if (i == 2) {
        // Two strings take one concatenation and no buffer.
        s[top - 2] = (s[top - 2] as String) + (s[top - 1] as String);
      } else {
        final sb = StringBuffer();
        for (var j = i; j > 0; j--) {
          sb.write(s[top - j] as String);
        }
        s[top - n] = sb.toString();
      }
    }
    total -= n - 1;
    L.top -= n - 1;
  } while (total > 1);
}

int _fb2int(int x) {
  final e = (x >> 3) & 0x1f;
  if (e == 0) return x;
  return ((x & 7) + 8) << (e - 1);
}

LuaClosure? _getCached(LuaThread L, LuaProto p, List<UpVal> encup, int base) {
  final c = p.cache;
  if (c is! LuaClosure) return null;
  final uv = p.upvalues;
  for (var i = 0; i < uv.length; i++) {
    final u = c.upvals[i];
    if (uv[i].inStack) {
      if (!identical(u.thread, L) || u.index != base + uv[i].index) return null;
    } else if (!identical(u, encup[uv[i].index])) {
      return null;
    }
  }
  return c;
}

LuaClosure _pushClosure(LuaThread L, LuaProto p, List<UpVal> encup, int base) {
  final uv = p.upvalues;
  final ups = List<UpVal>.generate(
    uv.length,
    (i) => uv[i].inStack ? L.findUpval(base + uv[i].index) : encup[uv[i].index],
  );
  final ncl = LuaClosure(p, ups);
  p.cache = ncl;
  return ncl;
}

/// `luaV_execute`. Runs the current Lua frame and the Lua frames that it
/// calls until a frame returns that was not entered by reentry.
void execute(LuaThread L) {
  final stack = L.stack;
  final mode = L.vm.numberMode;
  final rt = L.vm.runtime;
  var ci = L.ci;
  newframe:
  while (true) {
    final cl = ci.cl!;
    final p = cl.p;
    final k = p.constants;
    final kh = p.constHash;
    final code = p.code;
    final base = ci.base;
    while (true) {
      final i = code[ci.savedPc++];
      final ra = base + ((i >> 6) & 0xFF);
      switch (i & 0x3F) {
        case Op.MOVE:
          stack[ra] = stack[base + argB(i)];
        case Op.LOADK:
          stack[ra] = k[argBx(i)];
        case Op.LOADKX:
          stack[ra] = k[argAx(code[ci.savedPc++])];
        case Op.LOADBOOL:
          stack[ra] = argB(i) != 0;
          if (argC(i) != 0) ci.savedPc++;
        case Op.LOADNIL:
          var b = argB(i);
          var r = ra;
          do {
            stack[r++] = null;
          } while (b-- > 0);
        case Op.GETUPVAL:
          stack[ra] = cl.upvals[argB(i)].v;
        case Op.GETTABUP:
          final b = argB(i);
          final c = argC(i);
          final key = isK(c) ? k[c & 0xFF] : stack[base + c];
          final t = cl.upvals[b].v;
          if (t is LuaTable && key is String) {
            final v = isK(c) ? t.getStrH(key, kh[c & 0xFF]) : t.getStr(key);
            if (v != null || fastTM(t.metatable, TM.index) == null) {
              stack[ra] = v;
              continue;
            }
          }
          getTable(L, t, key, ra, ~b);
        case Op.GETTABLE:
          final b = base + argB(i);
          final c = argC(i);
          final key = isK(c) ? k[c & 0xFF] : stack[base + c];
          final t = stack[b];
          if (t is LuaTable) {
            final v = isK(c) && key is String
                ? t.getStrH(key, kh[c & 0xFF])
                : t.get(key);
            if (v != null || fastTM(t.metatable, TM.index) == null) {
              stack[ra] = v;
              continue;
            }
          }
          getTable(L, t, key, ra, b);
        case Op.SETTABUP:
          final b = argB(i);
          final c = argC(i);
          final a = argA(i);
          setTable(
            L,
            cl.upvals[a].v,
            isK(b) ? k[b & 0xFF] : stack[base + b],
            isK(c) ? k[c & 0xFF] : stack[base + c],
            ~a,
          );
        case Op.SETUPVAL:
          cl.upvals[argB(i)].v = stack[ra];
        case Op.SETTABLE:
          final b = argB(i);
          final c = argC(i);
          setTable(
            L,
            stack[ra],
            isK(b) ? k[b & 0xFF] : stack[base + b],
            isK(c) ? k[c & 0xFF] : stack[base + c],
            ra,
          );
        case Op.NEWTABLE:
          stack[ra] = LuaTable(_fb2int(argB(i)), _fb2int(argC(i)));
        case Op.SELF:
          final b = base + argB(i);
          final c = argC(i);
          final rb = stack[b];
          stack[ra + 1] = rb;
          final key = isK(c) ? k[c & 0xFF] : stack[base + c];
          if (rb is LuaTable && isK(c) && key is String) {
            final v = rb.getStrH(key, kh[c & 0xFF]);
            if (v != null || fastTM(rb.metatable, TM.index) == null) {
              stack[ra] = v;
              continue;
            }
          }
          getTable(L, rb, key, ra, b);
        case Op.ADD:
        case Op.SUB:
        case Op.MUL:
        case Op.DIV:
        case Op.MOD:
        case Op.POW:
          final b = argB(i);
          final c = argC(i);
          final rb = isK(b) ? k[b & 0xFF] : stack[base + b];
          final rc = isK(c) ? k[c & 0xFF] : stack[base + c];
          final ev = (i & 0x3F) - Op.ADD + TM.add;
          if (rb is double && rc is double) {
            // alloc: a Lua number on the stack is a boxed double
            stack[ra] = arithOp64(ev, rb, rc);
          } else {
            arith(
              L,
              ra,
              rb,
              rc,
              ev,
              isK(b) ? noLoc : base + b,
              isK(c) ? noLoc : base + c,
            );
          }
        case opFloat32:
        case opSub32:
        case opMul32:
        case opDiv32:
        case opMod32:
        case opPow32:
          final b = argB(i);
          final c = argC(i);
          final rb = isK(b) ? k[b & 0xFF] : stack[base + b];
          final rc = isK(c) ? k[c & 0xFF] : stack[base + c];
          final ev = (i & 0x3F) - opFloat32 + TM.add;
          if (rb is double && rc is double) {
            // alloc: a Lua number on the stack is a boxed double
            stack[ra] = arithOp(ev, rb, rc);
          } else {
            arith(
              L,
              ra,
              rb,
              rc,
              ev,
              isK(b) ? noLoc : base + b,
              isK(c) ? noLoc : base + c,
            );
          }
        case opSingle:
        case opSubSingle:
        case opMulSingle:
        case opDivSingle:
        case opModSingle:
        case opPowSingle:
          final b = argB(i);
          final c = argC(i);
          final rb = isK(b) ? k[b & 0xFF] : stack[base + b];
          final rc = isK(c) ? k[c & 0xFF] : stack[base + c];
          final ev = (i & 0x3F) - opSingle + TM.add;
          if (rb is double && rc is double) {
            // alloc: a Lua number on the stack is a boxed double
            stack[ra] = arithSingle(ev, rb, rc, rt);
          } else {
            arith(
              L,
              ra,
              rb,
              rc,
              ev,
              isK(b) ? noLoc : base + b,
              isK(c) ? noLoc : base + c,
            );
          }
        case Op.UNM:
          final b = base + argB(i);
          final rb = stack[b];
          if (rb is double) {
            stack[ra] = -rb;
          } else {
            arith(L, ra, rb, rb, TM.unm, b, b);
          }
        case Op.NOT:
          stack[ra] = isFalse(stack[base + argB(i)]);
        case Op.LEN:
          final b = base + argB(i);
          objLen(L, ra, stack[b], b);
        case Op.CONCAT:
          final b = argB(i);
          final c = argC(i);
          L.top = base + c + 1;
          concat(L, c - b + 1);
          stack[ra] = stack[base + b];
          L.top = ci.top;
        case Op.JMP:
          final a = argA(i);
          if (a > 0) L.closeUpvals(base + a - 1);
          ci.savedPc += argSBx(i);
        case Op.EQ:
        case Op.LT:
        case Op.LE:
          final b = argB(i);
          final c = argC(i);
          final rb = isK(b) ? k[b & 0xFF] : stack[base + b];
          final rc = isK(c) ? k[c & 0xFF] : stack[base + c];
          final op = i & 0x3F;
          final res = op == Op.EQ
              ? equalObj(L, rb, rc)
              : op == Op.LT
              ? lessThan(L, rb, rc)
              : lessEqual(L, rb, rc);
          if ((res ? 1 : 0) != argA(i)) {
            ci.savedPc++;
          } else {
            final j = code[ci.savedPc];
            final a = argA(j);
            if (a > 0) L.closeUpvals(base + a - 1);
            ci.savedPc += argSBx(j) + 1;
          }
        case Op.TEST:
          if (argC(i) != 0 ? isFalse(stack[ra]) : !isFalse(stack[ra])) {
            ci.savedPc++;
          } else {
            final j = code[ci.savedPc];
            final a = argA(j);
            if (a > 0) L.closeUpvals(base + a - 1);
            ci.savedPc += argSBx(j) + 1;
          }
        case Op.TESTSET:
          final rb = stack[base + argB(i)];
          if (argC(i) != 0 ? isFalse(rb) : !isFalse(rb)) {
            ci.savedPc++;
          } else {
            stack[ra] = rb;
            final j = code[ci.savedPc];
            final a = argA(j);
            if (a > 0) L.closeUpvals(base + a - 1);
            ci.savedPc += argSBx(j) + 1;
          }
        case Op.CALL:
          final b = argB(i);
          final nresults = argC(i) - 1;
          if (b != 0) L.top = ra + b;
          if (L.precall(ra, nresults)) {
            if (nresults >= 0) L.top = ci.top;
          } else {
            ci = L.ci;
            ci.callStatus |= cistReentry;
            continue newframe;
          }
        case Op.TAILCALL:
          final b = argB(i);
          if (b != 0) L.top = ra + b;
          if (!L.precall(ra, luaMultRet)) {
            final nci = L.ci;
            final oci = L.cis[L.ciIndex - 1];
            final nfunc = nci.func;
            final ofunc = oci.func;
            final lim = nci.base + nci.cl!.p.numParams;
            if (p.protos.isNotEmpty) L.closeUpvals(oci.base);
            for (var aux = 0; nfunc + aux < lim; aux++) {
              stack[ofunc + aux] = stack[nfunc + aux];
            }
            oci.base = ofunc + (nci.base - nfunc);
            oci.top = L.top = ofunc + (L.top - nfunc);
            oci.savedPc = nci.savedPc;
            oci.callStatus |= cistTail;
            oci.cl = nci.cl;
            L.ciIndex--;
            ci = oci;
            continue newframe;
          }
        case Op.RETURN:
          final b = argB(i);
          if (b != 0) L.top = ra + b - 1;
          if (p.protos.isNotEmpty) L.closeUpvals(base);
          final fixed = L.poscall(ra);
          if (ci.callStatus & cistReentry == 0) return;
          ci = L.ci;
          if (fixed) L.top = ci.top;
          continue newframe;
        case Op.FORLOOP:
          final step = stack[ra + 2] as double;
          final idx = f64((stack[ra] as double) + step);
          final limit = stack[ra + 1] as double;
          if (0 < step ? idx <= limit : limit <= idx) {
            ci.savedPc += argSBx(i);
            // alloc: a Lua number on the stack is a boxed double
            stack[ra] = idx;
            // alloc: a Lua number on the stack is a boxed double
            stack[ra + 3] = idx;
          }
        case opForLoop32:
          final step = stack[ra + 2] as double;
          final idx = f32((stack[ra] as double) + step);
          final limit = stack[ra + 1] as double;
          if (0 < step ? idx <= limit : limit <= idx) {
            ci.savedPc += argSBx(i);
            // alloc: a Lua number on the stack is a boxed double
            stack[ra] = idx;
            // alloc: a Lua number on the stack is a boxed double
            stack[ra + 3] = idx;
          }
        case Op.FORPREP:
          final init = toNumberValue(stack[ra], mode);
          if (init == null) L.runError("'for' initial value must be a number");
          // alloc: a Lua number on the stack is a boxed double
          stack[ra] = init;
          final limit = toNumberValue(stack[ra + 1], mode);
          if (limit == null) L.runError("'for' limit must be a number");
          // alloc: a Lua number on the stack is a boxed double
          stack[ra + 1] = limit;
          final step = toNumberValue(stack[ra + 2], mode);
          if (step == null) L.runError("'for' step must be a number");
          // alloc: a Lua number on the stack is a boxed double
          stack[ra + 2] = step;
          // alloc: a Lua number on the stack is a boxed double
          stack[ra] = f64(init - step);
          ci.savedPc += argSBx(i);
        case opForPrep32:
          final init = toNumberValue(stack[ra], mode);
          if (init == null) L.runError("'for' initial value must be a number");
          // alloc: a Lua number on the stack is a boxed double
          stack[ra] = init;
          final limit = toNumberValue(stack[ra + 1], mode);
          if (limit == null) L.runError("'for' limit must be a number");
          // alloc: a Lua number on the stack is a boxed double
          stack[ra + 1] = limit;
          final step = toNumberValue(stack[ra + 2], mode);
          if (step == null) L.runError("'for' step must be a number");
          // alloc: a Lua number on the stack is a boxed double
          stack[ra + 2] = step;
          // alloc: a Lua number on the stack is a boxed double
          stack[ra] = f32(init - step);
          ci.savedPc += argSBx(i);
        case Op.TFORCALL:
          final cb = ra + 3;
          stack[cb + 2] = stack[ra + 2];
          stack[cb + 1] = stack[ra + 1];
          stack[cb] = stack[ra];
          L.top = cb + 3;
          if (L.precall(cb, argC(i))) {
            L.top = ci.top;
          } else {
            ci = L.ci;
            ci.callStatus |= cistReentry;
            continue newframe;
          }
        case Op.TFORLOOP:
          if (stack[ra + 1] != null) {
            stack[ra] = stack[ra + 1];
            ci.savedPc += argSBx(i);
          }
        case Op.SETLIST:
          var n = argB(i);
          var c = argC(i);
          if (n == 0) n = L.top - ra - 1;
          if (c == 0) c = argAx(code[ci.savedPc++]);
          final h = stack[ra] as LuaTable;
          var last = (c - 1) * lFieldsPerFlush + n;
          if (last > h.sizeArray) h.resizeArray(last);
          for (; n > 0; n--) {
            h.setInt(last--, stack[ra + n]);
          }
          L.top = ci.top;
        case Op.CLOSURE:
          final np = p.protos[argBx(i)];
          stack[ra] =
              _getCached(L, np, cl.upvals, base) ??
              _pushClosure(L, np, cl.upvals, base);
        case Op.VARARG:
          var b = argB(i) - 1;
          final n = base - ci.func - p.numParams - 1;
          if (b < 0) {
            b = n;
            L.checkStack(n);
            L.top = ra + n;
          }
          for (var j = 0; j < b; j++) {
            stack[ra + j] = j < n ? stack[base - n + j] : null;
          }
        default:
          throw StateError('bad opcode ${i & 0x3F}');
      }
    }
  }
}
