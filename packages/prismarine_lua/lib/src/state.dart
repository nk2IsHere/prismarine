// Ported from Lua 5.2.3 lstate.c, ldo.c, lfunc.c and parts of lapi.c /
// lauxlib.c (MIT; see LICENSE-lua). A LuaThread is a lua_State: its own
// stack and CallInfo list; Lua→Lua calls push frames in the dispatch loop
// (vm.dart), natives are Dart functions with a C-API-like view of the stack.

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

// Thread and call status codes (lua.h).
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

// CallInfo status bits (lstate.h).
const cistLua = 1 << 0;
const cistHooked = 1 << 1;
const cistReentry = 1 << 2;
const cistYielded = 1 << 3;
const cistYPcall = 1 << 4;
const cistStat = 1 << 5;
const cistTail = 1 << 6;

/// A Lua error in flight (`luaD_throw`): the error value and its status.
class LuaError implements Exception {
  LuaError(this.value, {this.status = luaErrRun, this.traceback});
  Object? value;
  final int status;

  /// `debug.traceback` text captured where the error was raised (before the
  /// stack unwound), for diagnostics.
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

/// An upvalue: open (a live stack slot of [thread]) or closed (its own value).
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

/// A native function (`lua_CFunction`): reads its arguments from the
/// thread's stack, pushes its results and returns how many it pushed.
typedef LuaCFunction = int Function(LuaThread L);

class LuaNative extends LuaFunction {
  LuaNative(this.fn, [this.name]);
  final LuaCFunction fn;

  /// For diagnostics only; Lua names functions from the call site.
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

/// The global state: registry, globals, type metatables, configuration and
/// host.
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

  /// Compiles text chunks; without one, only binary chunks load.
  final LuaCompiler? compiler;
  final LuaTable registry = LuaTable(2, 0);
  late final LuaTable globals;
  late final LuaThread mainThread;

  /// Metatables of the non-table, non-userdata types (`G(L)->mt`), by type
  /// name; the string library sets `string`.
  final typeMetatables = <String, LuaTable>{};

  /// The random generator of `math.random`, which the host may share. It
  /// can outlive a Lua state and pass to a successor VM (see
  /// formats/telltale/lua-runtime.md, "The engine generator").
  final LuaRng rng;

  /// Capture `debug.traceback` text into raised errors.
  bool captureTracebacks = true;

  LuaTable? metatableOf(Object? v) => switch (v) {
    LuaTable t => t.metatable,
    LuaUserdata u => u.metatable,
    _ => typeMetatables[luaTypeName(v)],
  };

  /// Loads a chunk as a function whose first upvalue (`_ENV`) is [env] or
  /// the globals (`lua_load`). Text chunks go through [compiler].
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

  /// `lua_newthread` with [fn] pushed as its body (`coroutine.create`).
  LuaThread newThread([Object? fn]) {
    final t = LuaThread.child(this);
    if (fn != null) t.stack[t.top++] = fn;
    return t;
  }

  /// Calls [fn] with [args] on the main thread (non-yieldable) and returns
  /// its results. A Lua error is rethrown after the stack is restored.
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

  /// The stack; a growable list whose identity never changes.
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

  /// Stack index of the active error handler (`errfunc`), 0 = none.
  int errFunc = 0;

  /// Open upvalues, sorted by stack index (ascending).
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

  // --- stack ----------------------------------------------------------------

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

  /// `luaD_shrinkstack` (after an error is caught).
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

  // --- upvalues (lfunc.c) -----------------------------------------------------

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

  // --- calls (ldo.c) ------------------------------------------------------------

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

  /// `luaD_precall`: a native runs to completion (true); a Lua function gets
  /// a new frame and returns false (the caller runs it).
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

  /// `luaD_poscall`: moves the results to the function's slot; true unless
  /// the caller wanted all results.
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

  /// `luaD_call`: calls the function at [func] with the values above it.
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

  /// Runs [body] like `luaD_pcall`/`luaD_rawrunprotected`: on a Lua error
  /// the stack, frames, upvalues and counters return to their state at
  /// entry ([oldTop] becomes the top) and the error is rethrown.
  void protectedCall(void Function() body, int oldTop) {
    final oldCi = ciIndex;
    final oldNny = nny;
    final oldNCcalls = nCcalls;
    final oldErrFunc = errFunc;
    try {
      body();
    } catch (_) {
      // Lua errors and Dart exceptions from natives alike: restore, rethrow.
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

  // --- errors (ldebug.c luaG_runerror / luaG_errormsg) --------------------------

  /// `luaG_errormsg`: calls the error handler (if any) on the value, then
  /// throws.
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

  /// `luaG_runerror`: [msg] with the current Lua frame's `chunk:line:`.
  Never runError(String msg) {
    final ci = this.ci;
    if (ci.isLua) {
      final p = ci.cl!.p;
      msg = '${chunkId(p.source ?? '?')}:${p.lineAt(ci.savedPc - 1)}: $msg';
    }
    throwError(msg);
  }

  // --- coroutines (ldo.c lua_resume / lua_yieldk) ---------------------------------

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
      // A native yielded (no continuations): the resume arguments are its
      // results.
      poscall(firstArg);
      // unroll: finish the interrupted CALL/TFORCALL and run on.
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

  /// `lua_resume`: starts or continues this thread with the [nargs] values
  /// on its stack top. Returns [luaOk] (finished), [luaYield], or an error
  /// status (the error object is then on the top and the thread is dead,
  /// unless the resume itself was invalid).
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
      // A Dart exception from a native: the thread is dead; propagate.
      status = luaErrRun;
      nny = oldNny;
      nCcalls--;
      rethrow;
    }
    nny = oldNny;
    nCcalls--;
    return result;
  }

  /// Resumes with [args] from Dart: the yielded or returned values, or the
  /// error ([LuaResume.error]).
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

  /// `lua_yield`: suspends the running coroutine with the [nresults] top
  /// values. Only natives called directly from Lua code can yield; call it
  /// as `return L.yield(n);`. On the next resume its arguments become the
  /// native's results.
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
    // Control flow, not an error: no stack trace to collect (a plain throw
    // builds one each yield; the game's threads yield every frame).
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

  // --- the native API (lapi.c / lauxlib.c) --------------------------------------

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

  /// The value at [idx] (1-based from the native's base, negative from the
  /// top); null beyond the top. [luaRegistryIndex] is the registry.
  Object? arg(int idx) {
    if (idx == luaRegistryIndex) return vm.registry;
    if (idx > 0) {
      final o = ci.func + idx;
      return o < top ? stack[o] : null;
    }
    return stack[top + idx];
  }

  /// True when [idx] is beyond the top (`lua_isnone`).
  bool isNone(int idx) => idx > 0 && ci.func + idx >= top;

  void set(int idx, Object? v) => stack[_index(idx)] = v;

  void push(Object? v) {
    if (top >= stackLast) checkStack(1);
    stack[top++] = v;
  }

  void pushValue(int idx) => push(arg(idx));

  void pop([int n = 1]) => top -= n;

  /// `lua_insert`: moves the top value to [idx].
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

  /// `lua_replace`: pops the top value into [idx].
  void replace(int idx) {
    stack[_index(idx)] = stack[top - 1];
    top--;
  }

  /// `lua_call`: calls the function below the [nargs] top values.
  void call(int nargs, int nresults) {
    final func = top - (nargs + 1);
    callAt(func, nresults);
    if (nresults == luaMultRet && ci.top < top) ci.top = top;
  }

  /// `lua_pcall`: calls the function below the [nargs] top values; on an
  /// error the error object replaces the function and the status is returned.
  /// [msgh] is the stack index of a message handler, or 0.
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
      // A Dart exception from a native is a bug, not a Lua error: restore the
      // thread to its state at the pcall and let it propagate.
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

  /// `lua_error`: raises the value on top.
  Never error() => throwError(stack[top - 1]);

  /// `luaL_where(L, 1)`: the calling Lua function's `chunk:line: ` or ''.
  String where(int level) {
    final c = callInfoAt(level);
    if (c != null && c.isLua) {
      final p = c.cl!.p;
      final line = p.lineAt(c.savedPc - 1);
      if (line > 0) return '${chunkId(p.source ?? '?')}:$line: ';
    }
    return '';
  }

  /// `luaL_error`: [msg] with `where(1)`.
  Never luaError(String msg) => throwError('${where(1)}$msg');

  /// The CallInfo at stack [level] (0 = the running function), or null.
  CallInfo? callInfoAt(int level) {
    final i = ciIndex - level;
    return i > 0 ? cis[i] : null;
  }

  // luaL_check*/opt* helpers.

  Never argError(int narg, String extramsg) =>
      argErrorImpl(this, narg, extramsg);

  Never typeErrorArg(int narg, String tname) {
    final v = arg(narg);
    argError(
      narg,
      '$tname expected, got ${isNone(narg) ? 'no value' : luaTypeName(v)}',
    );
  }

  /// `lua_tonumberx`: numbers and numeric strings, else null.
  double? toNumber(int idx) {
    final v = arg(idx);
    if (v is double) return v;
    if (v is String) return parseLuaNumber(v, vm.numberMode);
    return null;
  }

  /// `lua_tolstring`: strings, and numbers converted in place; else null.
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

  /// `luaL_checkinteger`: the configuration's `lua_Integer`.
  int checkInteger(int i) => luaToInteger(checkNumber(i), vm.integer64);

  int optInteger(int i, int d) => arg(i) == null ? d : checkInteger(i);

  /// `luaL_checkint`: `(int)luaL_checkinteger`.
  int checkInt(int i) => luaToCInt(checkNumber(i), vm.integer64);

  int optInt(int i, int d) => arg(i) == null ? d : checkInt(i);

  int checkUnsigned(int i) => numberToUnsigned(checkNumber(i));

  String checkString(int i) => toStr(i) ?? typeErrorArg(i, 'string');

  String? optString(int i, String? d) => arg(i) == null ? d : checkString(i);

  LuaTable checkTable(int i) {
    final v = arg(i);
    return v is LuaTable ? v : typeErrorArg(i, 'table');
  }

  /// `lua_getglobal`: pushes `_G[name]` (honouring `_G`'s metatable).
  void getGlobal(String name) {
    push(null);
    getTable(this, vm.globals, name, top - 1, noLoc);
  }

  /// `lua_getfield`: pushes `t[k]` (with metamethods) for the value at [idx].
  void getField(int idx, String k) {
    final t = arg(idx);
    push(null);
    getTable(this, t, k, top - 1, noLoc);
  }

  /// `lua_gettable`: replaces the key on top with `t[key]` (with
  /// metamethods) for the table at [idx].
  void getTableAt(int idx) {
    final t = arg(idx);
    final k = stack[top - 1];
    stack[top - 1] = null;
    getTable(this, t, k, top - 1, noLoc);
  }

  /// `lua_setfield`: `t[k] = v` (with metamethods) for the value at [idx]
  /// and the value on top, which is popped.
  void setField(int idx, String k) {
    final t = arg(idx);
    final v = arg(-1);
    pop();
    setTable(this, t, k, v, noLoc);
  }

  /// `lua_rawgeti`: pushes `t[n]` (raw) of the table at [idx].
  void rawGetI(int idx, int n) => push((arg(idx) as LuaTable).getInt(n));

  /// `lua_rawseti`: pops the top value into `t[n]` (raw) of the table at [idx].
  void rawSetI(int idx, int n) {
    final t = arg(idx) as LuaTable;
    final v = stack[top - 1];
    top--;
    t.setInt(n, v);
  }

  /// `luaL_len`: `#` of the value at [idx] (with `__len`), as an int.
  int lenOf(int idx) {
    final v = arg(idx);
    push(null);
    objLen(this, top - 1, v, noLoc);
    final n = arg(-1);
    pop();
    if (n is! double) luaError('object length is not a number');
    return luaToCInt(n, vm.integer64);
  }

  /// `luaL_getmetafield`: the raw field [event] of the value's metatable.
  Object? getMetaField(int obj, String event) =>
      vm.metatableOf(arg(obj))?.get(event);

  /// `luaL_callmeta`: pushes `mt[event](obj)` and returns true, or false.
  bool callMeta(int obj, String event) {
    final f = getMetaField(obj, event);
    if (f == null) return false;
    final o = arg(obj);
    push(f);
    push(o);
    call(1, 1);
    return true;
  }

  /// The text `%p` prints for an object (`lua_topointer`).
  String pointerText(Object? v) =>
      vm.runtime.pointerText(v is LuaObject ? v.id : 0);

  /// [x], a C double result, as a `lua_Number` of the VM's mode.
  @pragma('vm:prefer-inline')
  double number(double x) => luaNumber(x, vm.float32);

  /// `luaL_tolstring`: pushes the value's text (`__tostring`, or the
  /// default) and returns it (`lua_tolstring` of the result; null if that
  /// is neither a string nor a number).
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

/// Whether [e], thrown through a native function, is the VM's own control
/// flow (a Lua error, a yield, a resume error, a bad table key) that a
/// native must let pass, as opposed to a host-side failure.
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

/// The outcome of [LuaThread.resume]: [status] is [luaOk] (finished),
/// [luaYield], or an error status with [error] set.
class LuaResume {
  LuaResume(this.status, this.values, {this.error});
  final int status;
  final List<Object?> values;
  final Object? error;
  bool get ok => status == luaOk || status == luaYield;
  bool get yielded => status == luaYield;
}
