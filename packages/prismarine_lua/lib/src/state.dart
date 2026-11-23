// Ported from Lua 5.2.3 lstate.c, ldo.c, lfunc.c and parts of lapi.c and
// lauxlib.c (MIT, see LICENSE-lua). A LuaThread is a lua_State with its own
// stack and CallInfo list. A call from Lua to Lua pushes a frame in the
// execute loop of vm.dart. A native is a Dart function with a view of the
// stack in the style of the C API.

import 'dart:typed_data';

import 'codec.dart';
import 'compiler.dart';
import 'debug.dart';
import 'host.dart';
import 'libs.dart';
import 'number.dart';
import 'opcodes.dart';
import 'config.dart';
import 'proto.dart';
import 'rng.dart';
import 'runtime.dart';
import 'table.dart';
import 'value.dart';
import 'vm.dart';

const luaMultRet = -1;

// The status codes of threads and calls, from lua.h.
const luaOk = 0, luaYield = 1, luaErrRun = 2, luaErrSyntax = 3;
const luaErrMem = 4, luaErrGcmm = 5, luaErrErr = 6;

/// `LUA_REGISTRYINDEX` for the API.
const luaRegistryIndex = -1001000;

const luaMinStack = 20;
const luaMaxStack = 1000000;
const _extraStack = 5;
const _basicStackSize = 2 * luaMinStack;
const _errorStackSize = luaMaxStack + 200;
const luaMaxCCalls = 200;

// The status bits of a CallInfo, from lstate.h.
const cistLua = 1 << 0;
const cistHooked = 1 << 1;
const cistReentry = 1 << 2;
const cistYielded = 1 << 3;
const cistYPcall = 1 << 4;
const cistStat = 1 << 5;
const cistTail = 1 << 6;

/// A Lua error in flight, as `luaD_throw` raises it, with its value and
/// status.
class LuaError implements Exception {
  LuaError(this.value, {this.status = luaErrRun, this.traceback});
  Object? value;
  final int status;

  /// The `debug.traceback` text at the place of the error, taken before the
  /// stack unwound.
  String? traceback;

  String get message => switch (value) {
    String s => s,
    double d => const LuaCRuntime().numberToString(d),
    null => 'nil',
    _ => '(error object is a ${luaTypeName(value)} value)',
  };

  @override
  String toString() => 'LuaError: $message';
}

/// An upvalue. An open upvalue is a live stack slot of [thread], and a
/// closed one holds its own value.
class UpVal {
  UpVal.open(LuaThread this.thread, this.index);
  UpVal.closed([this.value]);

  LuaThread? thread;
  int index = 0;
  Object? value;

  bool get isOpen => thread != null;

  Object? get v => thread == null ? value : thread!.stack[index];
  set v(Object? x) {
    final t = thread;
    if (t == null) {
      value = x;
    } else {
      t.stack[index] = x;
    }
  }
}

class LuaClosure extends LuaFunction {
  LuaClosure(this.p, this.upvals);
  final LuaProto p;
  final List<UpVal> upvals;
}

/// A native function, `lua_CFunction`. It reads its arguments from the stack
/// of the thread, pushes its results and returns their count.
typedef LuaCFunction = int Function(LuaThread L);

class LuaNative extends LuaFunction {
  LuaNative(this.fn, [this.name]);
  final LuaCFunction fn;

  /// The name for diagnostics. Lua gives a function the name of its call
  /// site.
  final String? name;
}

class CallInfo {
  int func = 0;
  int base = 0;
  int top = 0;
  int nresults = 0;
  int savedPc = 0;
  int callStatus = 0;
  int extra = 0;
  int oldErrFunc = 0;
  LuaClosure? cl;

  bool get isLua => callStatus & cistLua != 0;
}

/// The global state with the registry, the globals, the metatables of the
/// types, the configuration and the host.
class LuaVm {
  LuaVm({
    this.config = const LuaDefaultConfig(),
    LuaHost? host,
    bool openStd = true,
    this.compiler,
    LuaRng? rng,
  }) : host = host ?? MemoryLuaHost(),
       rng = rng ?? LuaRng(),
       numberMode = config.numberMode,
       float32 = config.numberMode.isFloat32,
       integer64 = config.integer64,
       runtime = config.runtime,
       mixedTypeEquality = config.mixedTypeEquality {
    luaClaimNumberMode(numberMode);
    mainThread = LuaThread._(this);
    globals = LuaTable();
    registry
      ..setInt(1, mainThread)
      ..setInt(2, globals);
    if (openStd) openLibs(this);
  }

  final LuaConfig config;
  final LuaHost host;

  /// The members of [config], read once.
  final LuaNumberMode numberMode;
  final bool float32;
  final bool integer64;
  final LuaCRuntime runtime;
  final bool mixedTypeEquality;

  /// Compiles text chunks. A VM without one loads binary chunks only.
  final LuaCompiler? compiler;
  final LuaTable registry = LuaTable(2, 0);
  late final LuaTable globals;
  late final LuaThread mainThread;

  /// The metatables of the types other than table and userdata by type name,
  /// `G(L)->mt`. The string library sets `string`.
  final typeMetatables = <String, LuaTable>{};

  /// The random generator of `math.random`, which the host may share. It can
  /// outlive a Lua state and pass to the next VM.
  final LuaRng rng;

  /// Raised errors carry the text of `debug.traceback`.
  bool captureTracebacks = true;

  LuaTable? metatableOf(Object? v) => switch (v) {
    LuaTable t => t.metatable,
    LuaUserdata u => u.metatable,
    _ => typeMetatables[luaTypeName(v)],
  };

  /// `lua_load`. Loads a chunk as a function whose first upvalue, `_ENV`, is
  /// [env] or else the globals. A text chunk goes through [compiler].
  LuaClosure load(Uint8List chunk, String chunkName, {LuaTable? env}) {
    LuaProto p;
    if (chunk.isNotEmpty && chunk[0] == 0x1B) {
      p = undumpLua(
        chunk,
        chunkName,
        sizeT: config.chunkSizeT,
        float32: float32,
      );
    } else {
      final c = compiler;
      if (c == null) {
        throw LuaLoadError(
          'no Lua compiler: a text chunk needs a VM made with a LuaCompiler',
        );
      }
      p = c.compile(String.fromCharCodes(chunk), chunkName);
    }
    specialiseProto(p, numberMode);
    LuaChunk(chunkName, chunk, p);
    final cl = LuaClosure(p, [
      for (var i = 0; i < p.upvalues.length; i++) UpVal.closed(),
    ]);
    if (cl.upvals.length == 1) cl.upvals[0].v = env ?? globals;
    return cl;
  }

  /// `lua_newthread` with [fn] pushed as its body, as `coroutine.create`
  /// does.
  LuaThread newThread([Object? fn]) {
    final t = LuaThread.child(this);
    if (fn != null) t.stack[t.top++] = fn;
    return t;
  }

  /// Calls [fn] with [args] on the main thread, which cannot yield here, and
  /// returns its results. A Lua error is rethrown after the stack is
  /// restored.
  List<Object?> call(Object? fn, List<Object?> args) {
    final L = mainThread;
    final base = L.top;
    L.checkStack(args.length + 1);
    L.stack[L.top++] = fn;
    for (final a in args) {
      L.stack[L.top++] = a;
    }
    L.protectedCall(() => L.callAt(base, luaMultRet), base);
    final res = L.stack.sublist(base, L.top);
    L.top = base;
    return res;
  }
}

class LuaThread extends LuaThreadBase {
  LuaThread._(this.vm) {
    _stackInit();
  }

  /// `lua_newthread`.
  LuaThread.child(this.vm) {
    _stackInit();
  }

  final LuaVm vm;

  /// The stack, a growable list that keeps its identity.
  final List<Object?> stack = <Object?>[];
  int stackSize = 0;
  int stackLast = 0;
  int top = 0;

  final cis = <CallInfo>[];
  int ciIndex = 0;
  CallInfo get ci => cis[ciIndex];

  int status = luaOk;
  int nny = 1;
  int nCcalls = 0;

  /// The stack index of the active error handler, `errfunc`, or 0.
  int errFunc = 0;

  /// The open upvalues in ascending order of stack index.
  final openUpvals = <UpVal>[];

  void _stackInit() {
    stack.length = _basicStackSize;
    stackSize = _basicStackSize;
    stackLast = stackSize - _extraStack;
    final base = CallInfo()
      ..func = 0
      ..callStatus = 0;
    stack[0] = null;
    top = 1;
    base.top = top + luaMinStack;
    cis.add(base);
    ciIndex = 0;
  }

  void _reallocStack(int newSize) {
    stack.length = newSize;
    stackSize = newSize;
    stackLast = newSize - _extraStack;
  }

  /// `luaD_growstack`.
  void growStack(int n) {
    if (stackSize > luaMaxStack) {
      throw LuaError('error in error handling', status: luaErrErr);
    }
    final needed = top + n + _extraStack;
    var newSize = 2 * stackSize;
    if (newSize > luaMaxStack) newSize = luaMaxStack;
    if (newSize < needed) newSize = needed;
    if (newSize > luaMaxStack) {
      _reallocStack(_errorStackSize);
      runError('stack overflow');
    }
    _reallocStack(newSize);
  }

  /// `luaD_checkstack`.
  void checkStack(int n) {
    if (stackLast - top <= n) growStack(n);
  }

  /// `luaD_shrinkstack` after a caught error.
  void shrinkStack() {
    var lim = top;
    for (var i = 0; i <= ciIndex; i++) {
      if (lim < cis[i].top) lim = cis[i].top;
    }
    final inuse = lim + 1;
    var goodSize = inuse + (inuse ~/ 8) + 2 * _extraStack;
    if (goodSize > luaMaxStack) goodSize = luaMaxStack;
    if (inuse <= luaMaxStack && goodSize < stackSize) _reallocStack(goodSize);
    if (cis.length > ciIndex + 1 + 1) cis.length = ciIndex + 2;
  }

  CallInfo _nextCi() {
    ciIndex++;
    if (ciIndex == cis.length) cis.add(CallInfo());
    return cis[ciIndex];
  }

  /// `luaF_findupval`.
  UpVal findUpval(int level) {
    var i = openUpvals.length - 1;
    while (i >= 0 && openUpvals[i].index >= level) {
      if (openUpvals[i].index == level) return openUpvals[i];
      i--;
    }
    final uv = UpVal.open(this, level);
    openUpvals.insert(i + 1, uv);
    return uv;
  }

  /// `luaF_close`.
  void closeUpvals(int level) {
    while (openUpvals.isNotEmpty && openUpvals.last.index >= level) {
      final uv = openUpvals.removeLast();
      uv.value = stack[uv.index];
      uv.thread = null;
    }
  }

  int _adjustVarargs(LuaProto p, int actual) {
    final nfix = p.numParams;
    checkStack(p.maxStackSize);
    final fixed = top - actual;
    final base = top;
    for (var i = 0; i < nfix; i++) {
      stack[top++] = stack[fixed + i];
      stack[fixed + i] = null;
    }
    return base;
  }

  int _tryFuncTM(int func) {
    final tm = getTMByObj(this, stack[func], TM.call);
    if (tm is! LuaFunction) typeError(this, stack[func], 'call', func);
    for (var p = top; p > func; p--) {
      stack[p] = stack[p - 1];
    }
    top++;
    checkStack(0);
    stack[func] = tm;
    return func;
  }

  /// `luaD_precall`. A native runs to completion and returns true. A Lua
  /// function gets a new frame and returns false, and the caller runs it.
  bool precall(int func, int nresults) {
    final f = stack[func];
    if (f is LuaClosure) {
      final p = f.p;
      var n = top - func - 1;
      checkStack(p.maxStackSize);
      for (; n < p.numParams; n++) {
        stack[top++] = null;
      }
      final base = p.isVararg ? _adjustVarargs(p, n) : func + 1;
      final ci = _nextCi()
        ..nresults = nresults
        ..func = func
        ..base = base
        ..top = base + p.maxStackSize
        ..savedPc = 0
        ..callStatus = cistLua
        ..cl = f;
      top = ci.top;
      return false;
    }
    if (f is LuaNative) {
      checkStack(luaMinStack);
      _nextCi()
        ..nresults = nresults
        ..func = func
        ..base = func + 1
        ..top = top + luaMinStack
        ..callStatus = 0
        ..cl = null;
      int n;
      try {
        n = f.fn(this);
      } on LuaTableKeyError catch (e) {
        runError(e.message);
      }
      poscall(top - n);
      return true;
    }
    return precall(_tryFuncTM(func), nresults);
  }

  /// `luaD_poscall`. Moves the results to the slot of the function. Returns
  /// true unless the caller wanted all results.
  bool poscall(int firstResult) {
    final ci = this.ci;
    var res = ci.func;
    final wanted = ci.nresults;
    ciIndex--;
    var i = wanted;
    for (; i != 0 && firstResult < top; i--) {
      stack[res++] = stack[firstResult++];
    }
    while (i-- > 0) {
      stack[res++] = null;
    }
    top = res;
    return wanted != luaMultRet;
  }

  /// `luaD_call`. Calls the function at [func] with the values above it.
  void callAt(int func, int nresults, {bool allowYield = false}) {
    if (++nCcalls >= luaMaxCCalls) {
      if (nCcalls == luaMaxCCalls) {
        runError('C stack overflow');
      } else if (nCcalls >= luaMaxCCalls + (luaMaxCCalls >> 3)) {
        throw LuaError('error in error handling', status: luaErrErr);
      }
    }
    if (!allowYield) nny++;
    if (!precall(func, nresults)) execute(this);
    if (!allowYield) nny--;
    nCcalls--;
  }

  /// Runs [body] as `luaD_pcall` and `luaD_rawrunprotected` do. On a Lua
  /// error the stack, frames, upvalues and counters return to their state at
  /// entry with [oldTop] as the top, and the error is rethrown.
  void protectedCall(void Function() body, int oldTop) {
    final oldCi = ciIndex;
    final oldNny = nny;
    final oldNCcalls = nCcalls;
    final oldErrFunc = errFunc;
    try {
      body();
    } catch (_) {
      // A Lua error and a Dart exception of a native alike restore the state
      // and rethrow.
      closeUpvals(oldTop);
      top = oldTop;
      ciIndex = oldCi;
      nny = oldNny;
      nCcalls = oldNCcalls;
      errFunc = oldErrFunc;
      shrinkStack();
      rethrow;
    }
    errFunc = oldErrFunc;
  }

  /// `luaG_errormsg`. Calls the error handler on the value when there is one
  /// and throws.
  Never throwError(Object? value) {
    if (errFunc != 0) {
      final h = stack[errFunc];
      if (h is! LuaFunction) throw LuaError(value, status: luaErrErr);
      checkStack(2);
      stack[top] = h;
      stack[top + 1] = value;
      top += 2;
      callAt(top - 2, 1);
      value = stack[--top];
    }
    throw LuaError(
      value,
      traceback: vm.captureTracebacks ? traceback(this, null, 1) : null,
    );
  }

  /// `luaG_runerror`. Raises [msg] after the `chunk:line:` of the current Lua
  /// frame.
  Never runError(String msg) {
    final ci = this.ci;
    if (ci.isLua) {
      final p = ci.cl!.p;
      msg = '${chunkId(p.source ?? '?')}:${p.lineAt(ci.savedPc - 1)}: $msg';
    }
    throwError(msg);
  }

  Never _resumeError(String msg, int firstArg) {
    top = firstArg;
    throw _ResumeError(msg);
  }

  void _resumeBody(int firstArg) {
    if (nCcalls >= luaMaxCCalls) _resumeError('C stack overflow', firstArg);
    if (status == luaOk) {
      if (ciIndex != 0) {
        _resumeError('cannot resume non-suspended coroutine', firstArg);
      }
      if (!precall(firstArg - 1, luaMultRet)) execute(this);
    } else if (status != luaYield) {
      _resumeError('cannot resume dead coroutine', firstArg);
    } else {
      status = luaOk;
      final c = ci;
      c.func = c.extra;
      // A native yielded without a continuation. The arguments of the resume
      // are its results.
      poscall(firstArg);
      // The unroll finishes the interrupted CALL or TFORCALL and runs on.
      while (ciIndex != 0) {
        final lc = ci;
        final inst = lc.cl!.p.code[lc.savedPc - 1];
        final op = opOf(inst);
        if (op == Op.TFORCALL || (op == Op.CALL && argC(inst) - 1 >= 0)) {
          top = lc.top;
        }
        execute(this);
      }
    }
  }

  /// `lua_resume`. Starts or continues this thread with the [nargs] values on
  /// the top of its stack. Returns [luaOk] when the thread finished, or
  /// [luaYield], or an error status. After an error the error object is on
  /// the top, and the thread is dead unless the resume itself was invalid.
  int resumeRaw(LuaThread? from, int nargs) {
    final oldNny = nny;
    nCcalls = from != null ? from.nCcalls + 1 : 1;
    nny = 0;
    var result = luaOk;
    try {
      _resumeBody(top - nargs);
    } on _LuaYield {
      result = luaYield;
    } on _ResumeError catch (e) {
      stack[top++] = e.message;
      result = luaErrRun;
    } on LuaError catch (e) {
      result = e.status;
      status = result;
      checkStack(1);
      stack[top++] = e.status == luaErrErr
          ? 'error in error handling'
          : e.value;
      ci.top = top;
    } catch (_) {
      // A Dart exception of a native kills the thread and propagates.
      status = luaErrRun;
      nny = oldNny;
      nCcalls--;
      rethrow;
    }
    nny = oldNny;
    nCcalls--;
    return result;
  }

  /// Resumes with [args] from Dart. Returns the yielded or returned values,
  /// or the error in [LuaResume.error].
  LuaResume resume(List<Object?> args, {LuaThread? from}) {
    checkStack(args.length);
    for (final a in args) {
      stack[top++] = a;
    }
    final st = resumeRaw(from, args.length);
    if (st == luaOk || st == luaYield) {
      final n = top - (ci.func + 1);
      final values = stack.sublist(top - n, top);
      top -= n;
      return LuaResume(st, values);
    }
    final err = stack[--top];
    return LuaResume(st, const [], error: err);
  }

  bool get isYieldable => nny == 0;

  /// `lua_yield`. Suspends the running coroutine with the [nresults] values
  /// on the top. Only a native that Lua code calls directly can yield, with
  /// `return L.yield(n);`. The arguments of the next resume become the
  /// results of the native.
  int yield(int nresults) {
    if (nny > 0) {
      if (!identical(this, vm.mainThread)) {
        runError('attempt to yield across a C-call boundary');
      }
      runError('attempt to yield from outside a coroutine');
    }
    status = luaYield;
    final c = ci;
    c.extra = c.func;
    c.func = top - nresults - 1;
    // A yield is control flow and collects no stack trace. Script threads
    // of a host may yield every frame.
    Error.throwWithStackTrace(const _LuaYield(), StackTrace.empty);
  }

  /// `coroutine.status` of this thread as seen from [running].
  String statusFrom(LuaThread running) {
    if (identical(this, running)) return 'running';
    if (status == luaYield) return 'suspended';
    if (status == luaOk) {
      if (ciIndex > 0) return 'normal';
      return top - (ci.func + 1) == 0 ? 'dead' : 'suspended';
    }
    return 'dead';
  }

  /// `lua_gettop`.
  int getTop() => top - (ci.func + 1);

  int _index(int idx) {
    if (idx > 0) return ci.func + idx;
    return top + idx;
  }

  /// `lua_settop`.
  void setTop(int idx) {
    final func = ci.func;
    if (idx >= 0) {
      while (top < func + 1 + idx) {
        stack[top++] = null;
      }
      top = func + 1 + idx;
    } else {
      top += idx + 1;
    }
  }

  /// The value at [idx], counted from 1 at the base of the native and from
  /// -1 at the top. Returns null beyond the top. [luaRegistryIndex] is the
  /// registry.
  Object? arg(int idx) {
    if (idx == luaRegistryIndex) return vm.registry;
    if (idx > 0) {
      final o = ci.func + idx;
      return o < top ? stack[o] : null;
    }
    return stack[top + idx];
  }

  /// `lua_isnone`, true when [idx] is beyond the top.
  bool isNone(int idx) => idx > 0 && ci.func + idx >= top;

  void set(int idx, Object? v) => stack[_index(idx)] = v;

  void push(Object? v) {
    if (top >= stackLast) checkStack(1);
    stack[top++] = v;
  }

  void pushValue(int idx) => push(arg(idx));

  void pop([int n = 1]) => top -= n;

  /// `lua_insert`. Moves the top value to [idx].
  void insert(int idx) {
    final p = _index(idx);
    final v = stack[top - 1];
    for (var q = top - 1; q > p; q--) {
      stack[q] = stack[q - 1];
    }
    stack[p] = v;
  }

  /// `lua_remove`.
  void remove(int idx) {
    var p = _index(idx);
    while (++p < top) {
      stack[p - 1] = stack[p];
    }
    top--;
  }

  /// `lua_replace`. Pops the top value into [idx].
  void replace(int idx) {
    stack[_index(idx)] = stack[top - 1];
    top--;
  }

  /// `lua_call`. Calls the function below the [nargs] values on the top.
  void call(int nargs, int nresults) {
    final func = top - (nargs + 1);
    callAt(func, nresults);
    if (nresults == luaMultRet && ci.top < top) ci.top = top;
  }

  /// `lua_pcall`. Calls the function below the [nargs] values on the top. On
  /// an error the error object replaces the function, and the status is
  /// returned. [msgh] is the stack index of a message handler, or 0.
  int pcall(int nargs, int nresults, int msgh) {
    final func = top - (nargs + 1);
    final oldErr = errFunc;
    errFunc = msgh == 0 ? 0 : _index(msgh);
    final oldCi = ciIndex, oldNny = nny, oldNCcalls = nCcalls;
    try {
      callAt(func, nresults);
      errFunc = oldErr;
      if (nresults == luaMultRet && ci.top < top) ci.top = top;
      return luaOk;
    } on LuaError catch (e) {
      closeUpvals(func);
      stack[func] = e.status == luaErrErr ? 'error in error handling' : e.value;
      top = func + 1;
      ciIndex = oldCi;
      nny = oldNny;
      nCcalls = oldNCcalls;
      errFunc = oldErr;
      shrinkStack();
      return e.status;
    } catch (_) {
      // A Dart exception of a native is a bug and not a Lua error. The
      // thread returns to its state at the pcall and the exception
      // propagates.
      closeUpvals(func);
      top = func;
      ciIndex = oldCi;
      nny = oldNny;
      nCcalls = oldNCcalls;
      errFunc = oldErr;
      shrinkStack();
      rethrow;
    }
  }

  /// `lua_copy`.
  void copy(int from, int to) => stack[_index(to)] = arg(from);

  /// `lua_error`. Raises the value on the top.
  Never error() => throwError(stack[top - 1]);

  /// `luaL_where(L, 1)`. Returns the `chunk:line: ` of the calling Lua
  /// function, or ''.
  String where(int level) {
    final c = callInfoAt(level);
    if (c != null && c.isLua) {
      final p = c.cl!.p;
      final line = p.lineAt(c.savedPc - 1);
      if (line > 0) return '${chunkId(p.source ?? '?')}:$line: ';
    }
    return '';
  }

  /// `luaL_error`. Raises [msg] after `where(1)`.
  Never luaError(String msg) => throwError('${where(1)}$msg');

  /// The CallInfo at stack [level], 0 for the running function, or null.
  CallInfo? callInfoAt(int level) {
    final i = ciIndex - level;
    return i > 0 ? cis[i] : null;
  }

  // The luaL_check and luaL_opt functions.

  Never argError(int narg, String extramsg) =>
      argErrorImpl(this, narg, extramsg);

  Never typeErrorArg(int narg, String tname) {
    final v = arg(narg);
    argError(
      narg,
      '$tname expected, got ${isNone(narg) ? 'no value' : luaTypeName(v)}',
    );
  }

  /// `lua_tonumberx`. Returns a number or a numeric string as a number, else
  /// null.
  double? toNumber(int idx) {
    final v = arg(idx);
    if (v is double) return v;
    if (v is String) return parseLuaNumber(v, vm.numberMode);
    return null;
  }

  /// `lua_tolstring`. Returns a string, or a number converted in place, else
  /// null.
  String? toStr(int idx) {
    final v = arg(idx);
    if (v is String) return v;
    if (v is double) {
      final s = vm.runtime.numberToString(v);
      if (!isNone(idx)) stack[_index(idx)] = s;
      return s;
    }
    return null;
  }

  double checkNumber(int i) => toNumber(i) ?? typeErrorArg(i, 'number');

  double? optNumber(int i, double? d) => arg(i) == null ? d : checkNumber(i);

  /// `luaL_checkinteger` with the `lua_Integer` of the configuration.
  int checkInteger(int i) => luaToInteger(checkNumber(i), vm.integer64);

  int optInteger(int i, int d) => arg(i) == null ? d : checkInteger(i);

  /// `luaL_checkint`, the `(int)` of `luaL_checkinteger`.
  int checkInt(int i) => luaToCInt(checkNumber(i), vm.integer64);

  int optInt(int i, int d) => arg(i) == null ? d : checkInt(i);

  int checkUnsigned(int i) => numberToUnsigned(checkNumber(i));

  String checkString(int i) => toStr(i) ?? typeErrorArg(i, 'string');

  String? optString(int i, String? d) => arg(i) == null ? d : checkString(i);

  LuaTable checkTable(int i) {
    final v = arg(i);
    return v is LuaTable ? v : typeErrorArg(i, 'table');
  }

  /// `lua_getglobal`. Pushes `_G[name]` through the metatable of `_G`.
  void getGlobal(String name) {
    push(null);
    getTable(this, vm.globals, name, top - 1, noLoc);
  }

  /// `lua_getfield`. Pushes `t[k]` with metamethods for the value at [idx].
  void getField(int idx, String k) {
    final t = arg(idx);
    push(null);
    getTable(this, t, k, top - 1, noLoc);
  }

  /// `lua_gettable`. Replaces the key on the top with `t[key]` with
  /// metamethods for the table at [idx].
  void getTableAt(int idx) {
    final t = arg(idx);
    final k = stack[top - 1];
    stack[top - 1] = null;
    getTable(this, t, k, top - 1, noLoc);
  }

  /// `lua_setfield`. Sets `t[k] = v` with metamethods for the value at [idx]
  /// and pops the value on the top.
  void setField(int idx, String k) {
    final t = arg(idx);
    final v = arg(-1);
    pop();
    setTable(this, t, k, v, noLoc);
  }

  /// `lua_rawgeti`. Pushes the raw `t[n]` of the table at [idx].
  void rawGetI(int idx, int n) => push((arg(idx) as LuaTable).getInt(n));

  /// `lua_rawseti`. Pops the top value into the raw `t[n]` of the table at
  /// [idx].
  void rawSetI(int idx, int n) {
    final t = arg(idx) as LuaTable;
    final v = stack[top - 1];
    top--;
    t.setInt(n, v);
  }

  /// `luaL_len`. Returns `#` of the value at [idx] with `__len` as an int.
  int lenOf(int idx) {
    final v = arg(idx);
    push(null);
    objLen(this, top - 1, v, noLoc);
    final n = arg(-1);
    pop();
    if (n is! double) luaError('object length is not a number');
    return luaToCInt(n, vm.integer64);
  }

  /// `luaL_getmetafield`. Returns the raw field [event] of the metatable of
  /// the value.
  Object? getMetaField(int obj, String event) =>
      vm.metatableOf(arg(obj))?.get(event);

  /// `luaL_callmeta`. Pushes `mt[event](obj)` and returns true, else false.
  bool callMeta(int obj, String event) {
    final f = getMetaField(obj, event);
    if (f == null) return false;
    final o = arg(obj);
    push(f);
    push(o);
    call(1, 1);
    return true;
  }

  /// The text of `%p` for an object, `lua_topointer`.
  String pointerText(Object? v) =>
      vm.runtime.pointerText(v is LuaObject ? v.id : 0);

  /// [x], a C double result, as a `lua_Number` of the VM's mode.
  @pragma('vm:prefer-inline')
  double number(double x) => luaNumber(x, vm.float32);

  /// `luaL_tolstring`. Pushes the text of the value from `__tostring` or the
  /// default and returns it as `lua_tolstring` of the result. Returns null
  /// when the result is neither a string nor a number.
  String? toLString(int idx) {
    if (!callMeta(idx, '__tostring')) {
      final v = arg(idx);
      push(switch (v) {
        null => 'nil',
        bool b => b ? 'true' : 'false',
        double() || String() => v,
        _ => '${luaTypeName(v)}: ${pointerText(v)}',
      });
    }
    return toStr(-1);
  }

  /// `luaL_checkoption`.
  int checkOption(int narg, String? def, List<String> options) {
    final name = def != null ? optString(narg, def)! : checkString(narg);
    final i = options.indexOf(name);
    if (i < 0) argError(narg, "invalid option '$name'");
    return i;
  }

  /// `luaL_checkany`.
  void checkAny(int i) {
    if (isNone(i)) argError(i, 'value expected');
  }

  /// `luaL_checktype` for a Lua type name.
  void checkType(int i, String tname) {
    if (isNone(i) || luaTypeName(arg(i)) != tname) typeErrorArg(i, tname);
  }
}

/// True when [e], thrown through a native function, is control flow of the
/// VM that a native must let pass, such as a Lua error, a yield, a resume
/// error or a bad table key. Returns false for a failure of the host.
bool isLuaSignal(Object e) =>
    e is LuaError ||
    e is _LuaYield ||
    e is _ResumeError ||
    e is LuaTableKeyError ||
    e is LuaLoadError;

class _LuaYield implements Exception {
  const _LuaYield();
}

class _ResumeError implements Exception {
  _ResumeError(this.message);
  final String message;
}

/// The outcome of [LuaThread.resume]. [status] is [luaOk] for a finished
/// thread, [luaYield] or an error status with [error] set.
class LuaResume {
  LuaResume(this.status, this.values, {this.error});
  final int status;
  final List<Object?> values;
  final Object? error;
  bool get ok => status == luaOk || status == luaYield;
  bool get yielded => status == luaYield;
}
