// Snapshot codecs for a Lua state (see formats/port/snapshot.md): tables,
// closures, natives, threads, userdata, upvalues, prototypes (by their chunk,
// loaded again) and the VM's own state. Every object keeps its id (table
// order hashes by it).
//
// A Lua state's boot objects — everything made while its owner built it:
// the libraries, the engine's natives and their tables — are named by their
// creation order and taken from the fresh state the reader built the same
// way; the rest are made new.
import 'dart:typed_data';

import 'package:prismarine_snap/prismarine_snap.dart';

import 'lib/base.dart' show luaSharedNatives;
import 'lib/io.dart' show luaIsIoHandle;
import 'proto.dart';
import 'rng.dart';
import 'state.dart';
import 'table.dart';
import 'value.dart';

/// One Lua state as a snapshot sees it: its VM, its boot objects (creation
/// order) and the owner's flags for it (the reader gets them back when it
/// makes the state again).
class LuaSnapState {
  LuaSnapState(this.vm, this.boot, {this.flags = 0});
  final LuaVm vm;
  final List<LuaObject> boot;
  final int flags;
}

/// The Lua state a snapshot covers, shared by the codecs through
/// [SnapWriter.env] / [SnapReader.env]: the current one. The writer also
/// knows the owner's closed states: a snapshot that reaches one of their
/// objects (an engine cache still holding a closed state's function) shows
/// a port bug, and the write fails naming it rather than carrying the dead
/// state along.
class LuaSnapEnv {
  /// The writer's: [current], and the owner's [closed] states.
  LuaSnapEnv.writer(
    LuaSnapState current, {
    List<LuaSnapState> closed = const [],
  }) : _states = [current, ...closed];

  /// The reader's: [current].
  LuaSnapEnv.reader(LuaSnapState current) : _states = [current];

  final List<LuaSnapState> _states;

  /// The current state's VM.
  LuaVm get vm => _states.first.vm;

  // Writer: object → (state, boot index); state 0 is the current one.
  late final Map<LuaObject, (int, int)> _index = () {
    final m = Map<LuaObject, (int, int)>.identity();
    for (var s = _states.length - 1; s >= 0; s--) {
      final boot = _states[s].boot;
      for (var i = 0; i < boot.length; i++) {
        m[boot[i]] = (s, i);
      }
    }
    return m;
  }();
  late final Map<LuaVm, int> _vmIndex = {
    for (var s = 0; s < _states.length; s++) _states[s].vm: s,
  };

  late final Map<LuaNative, String> _shared = {
    for (final e in luaSharedNatives.entries) e.value: e.key,
  };

  /// Writes [o]'s boot reference: 0 when it isn't a boot object, else the
  /// state's reference (1, the current one) and its index.
  bool _writeBoot(SnapWriter w, LuaObject o) {
    final at = _index[o];
    if (at == null) {
      w.uint(0);
      return false;
    }
    _writeState(w, at.$1, o);
    w.uint(at.$2);
    return true;
  }

  void _writeState(SnapWriter w, int state, Object what) {
    if (state != 0) {
      throw SnapError(
        'an object of a closed Lua state is still held: $what, by ${w.path}',
      );
    }
    w.uint(1);
  }

  LuaSnapState _readState(SnapReader r, int ref) {
    if (ref != 1) throw SnapError('an object of Lua state ${ref - 1}');
    return _states.first;
  }

  T? _readBoot<T extends LuaObject>(SnapReader r, String what) {
    final ref = r.uint();
    if (ref == 0) return null;
    final state = _readState(r, ref);
    final b = r.uint();
    if (b >= state.boot.length) {
      throw SnapError('$what: boot object $b of ${state.boot.length}');
    }
    final o = state.boot[b];
    if (o is! T) throw SnapError('$what: boot object $b is a ${o.runtimeType}');
    return o;
  }
}

LuaSnapEnv _envW(SnapWriter w) => w.env[LuaSnapEnv]! as LuaSnapEnv;
LuaSnapEnv _envR(SnapReader r) => r.env[LuaSnapEnv]! as LuaSnapEnv;

// The head of every Lua object: its id and its boot reference.
bool _head(SnapWriter w, LuaObject o) {
  w.uint(o.id);
  return _envW(w)._writeBoot(w, o);
}

T? _boot<T extends LuaObject>(SnapReader r, String what) =>
    _envR(r)._readBoot<T>(r, what);

/// Runs [build] (which makes a Lua state) and returns its result with the
/// Lua objects it made, in creation order: the state's boot objects. The
/// process-wide natives are made first, so they're never among them.
(T, List<LuaObject>) luaWithBoot<T>(T Function() build) {
  luaSharedNatives;
  final boot = <LuaObject>[];
  final outer = luaCollect;
  luaCollect = boot;
  try {
    return (build(), boot);
  } finally {
    luaCollect = outer;
  }
}

/// The host resource a chunk name names (`@file` as the loaders name a
/// file's chunk).
String _resourceOf(String chunkName) =>
    chunkName.startsWith('@') ? chunkName.substring(1) : chunkName;

/// FNV-1a over [b] (a chunk's identity check), computed once per byte
/// list (a chunk's bytes don't change).
int luaChunkHash(Uint8List b) => _chunkHashes[b] ??= _fnv(b);

final _chunkHashes = Expando<int>('lua chunk hash');

int _fnv(Uint8List b) {
  var h = 0xcbf29ce484222325;
  for (var i = 0; i < b.length; i++) {
    h = (h ^ b[i]) * 0x100000001b3;
  }
  return h;
}

/// Adds the Lua codecs to [reg].
void registerLuaSnap(SnapRegistry reg) {
  reg
    ..codec<LuaTable>(
      'lua.Table',
      writeNew: (w, o) => _head(w, o),
      make: (r) {
        final id = r.uint();
        final t = _boot<LuaTable>(r, 'table') ?? LuaTable();
        return t..id = id;
      },
      write: (w, o) => o.snapWrite(w),
      read: (r, o) => o.snapRead(r),
    )
    ..codec<LuaClosure>(
      'lua.Closure',
      writeNew: (w, o) {
        // Closures are always made new (none is an engine root).
        w.uint(o.id);
        w.ref(o.p);
        w.list(o.upvals, w.ref);
      },
      make: (r) {
        final id = r.uint();
        final p = r.ref<LuaProto>();
        final ups = r.list<UpVal>(r.ref<UpVal>);
        return LuaClosure(p, ups)..id = id;
      },
    )
    ..codec<LuaNative>(
      'lua.Native',
      writeNew: (w, o) {
        if (_head(w, o)) return;
        final shared = _envW(w)._shared[o];
        if (shared != null) {
          w.byte(1);
          w.str(shared);
          return;
        }
        if (snapFnRecipe(o.fn) == null) {
          throw SnapError(
            'a native that is neither a boot object nor has a recipe: '
            '${o.name} id ${o.id} (${w.where})',
          );
        }
        w.byte(2);
        w.value(o.fn);
        w.strOrNull(o.name);
      },
      make: (r) {
        final id = r.uint();
        final boot = _boot<LuaNative>(r, 'native');
        if (boot != null) return boot..id = id;
        if (r.byte() == 1) {
          final name = r.str();
          final n = luaSharedNatives[name];
          if (n == null) throw SnapError('no shared native $name');
          return n..id = id;
        }
        final fn = r.ref<LuaCFunction>();
        return LuaNative(fn, r.strOrNull())..id = id;
      },
    )
    ..codec<LuaThread>(
      'lua.Thread',
      writeNew: (w, o) {
        if (!_head(w, o)) w.ref(o.vm);
      },
      make: (r) {
        final id = r.uint();
        final t =
            _boot<LuaThread>(r, 'thread') ?? LuaThread.child(r.ref<LuaVm>());
        return t..id = id;
      },
      write: (w, o) {
        w.values(o.stack);
        w.uint(o.stackSize);
        w.uint(o.stackLast);
        w.uint(o.top);
        w.list(o.cis, (CallInfo ci) {
          w.int_(ci.func);
          w.int_(ci.base);
          w.int_(ci.top);
          w.int_(ci.nresults);
          w.int_(ci.savedPc);
          w.int_(ci.callStatus);
          w.int_(ci.extra);
          w.int_(ci.oldErrFunc);
          w.ref(ci.cl);
        });
        w.uint(o.ciIndex);
        w.int_(o.status);
        w.int_(o.nny);
        w.int_(o.nCcalls);
        w.int_(o.errFunc);
        w.list(o.openUpvals, w.ref);
      },
      read: (r, o) {
        final stack = r.values();
        o.stack
          ..length = 0
          ..addAll(stack);
        o.stackSize = r.uint();
        o.stackLast = r.uint();
        o.top = r.uint();
        final cis = r.list<CallInfo>(
          () => CallInfo()
            ..func = r.int_()
            ..base = r.int_()
            ..top = r.int_()
            ..nresults = r.int_()
            ..savedPc = r.int_()
            ..callStatus = r.int_()
            ..extra = r.int_()
            ..oldErrFunc = r.int_()
            ..cl = r.ref<LuaClosure?>(),
        );
        o.cis
          ..clear()
          ..addAll(cis);
        o.ciIndex = r.uint();
        o.status = r.int_();
        o.nny = r.int_();
        o.nCcalls = r.int_();
        o.errFunc = r.int_();
        r.listInto(o.openUpvals, r.ref<UpVal>);
      },
    )
    ..codec<LuaUserdata>(
      'lua.Userdata',
      writeNew: (w, o) => _head(w, o),
      make: (r) {
        final id = r.uint();
        final u = _boot<LuaUserdata>(r, 'userdata') ?? LuaUserdata();
        return u..id = id;
      },
      write: (w, o) {
        // A boot io handle keeps the fresh state's payload.
        final keep = luaIsIoHandle(o.payload) && _envW(w)._index.containsKey(o);
        w.boolean(keep);
        if (!keep) w.value(o.payload);
        w.ref(o.metatable);
        w.value(o.userValue);
      },
      read: (r, o) {
        if (!r.boolean()) o.payload = r.value();
        o.metatable = r.ref<LuaTable?>();
        o.userValue = r.value();
      },
    )
    ..codec<UpVal>(
      'lua.UpVal',
      writeNew: (w, o) {
        w.ref(o.thread);
        w.uint(o.index);
      },
      make: (r) {
        final t = r.ref<LuaThread?>();
        final i = r.uint();
        return t == null ? UpVal.closed() : UpVal.open(t, i);
      },
      write: (w, o) {
        w.ref(o.thread);
        w.uint(o.index);
        w.value(o.value);
      },
      read: (r, o) {
        o.thread = r.ref<LuaThread?>();
        o.index = r.uint();
        o.value = r.value();
      },
    )
    ..codec<LuaProto>(
      'lua.Proto',
      writeNew: (w, o) {
        final c = o.chunk;
        if (c == null) throw SnapError('a prototype without its chunk');
        w.ref(c);
        w.uint(o.chunkIndex);
      },
      make: (r) {
        final c = r.ref<LuaChunk>();
        return c.protos[r.uint()];
      },
      write: (w, o) => w.value(o.cache),
      read: (r, o) => o.cache = r.value(),
    )
    ..codec<LuaChunk>(
      'lua.Chunk',
      writeNew: (w, o) {
        final host = _envW(w).vm.host;
        final fromHost = o.fromHost ??= () {
          final b = host.readResource(_resourceOf(o.name));
          if (b == null || b.length != o.bytes.length) return false;
          for (var i = 0; i < b.length; i++) {
            if (b[i] != o.bytes[i]) return false;
          }
          return true;
        }();
        w.str(o.name);
        w.boolean(fromHost);
        if (fromHost) {
          w.uint(o.bytes.length);
          w.int_(luaChunkHash(o.bytes));
        } else {
          w.bytes(o.bytes);
        }
      },
      make: (r) {
        final vm = _envR(r).vm;
        final name = r.str();
        final Uint8List bytes;
        if (r.boolean()) {
          final n = r.uint(), h = r.int_();
          final b = vm.host.readResource(_resourceOf(name));
          if (b == null || b.length != n || luaChunkHash(b) != h) {
            throw SnapError('chunk $name is not the one the snapshot ran');
          }
          bytes = b;
        } else {
          bytes = r.bytes();
        }
        final c = vm.load(bytes, name).p.chunk!;
        return c..fromHost = null;
      },
      // Every prototype of a written chunk, for their closure caches.
      write: (w, o) => w.list(o.protos, w.ref),
      read: (r, o) {
        final n = r.uint();
        for (var i = 0; i < n; i++) {
          if (!identical(r.ref<LuaProto>(), o.protos[i])) {
            throw SnapError('chunk ${o.name}: prototype $i out of step');
          }
        }
      },
    )
    ..codec<LuaRng>(
      'lua.Rng',
      write: (w, o) {
        w.uint(o.x);
        w.uint(o.y);
        w.uint(o.z);
        w.uint(o.w);
      },
      read: (r, o) {
        o
          ..x = r.uint()
          ..y = r.uint()
          ..z = r.uint()
          ..w = r.uint();
      },
    )
    ..codec<LuaVm>(
      'lua.Vm',
      // The current VM is known to both sides; any other is a closed
      // state's.
      writeNew: (w, o) {
        final s = _envW(w)._vmIndex[o];
        if (s == null) throw SnapError('a VM of no Lua state');
        _envW(w)._writeState(w, s, o);
      },
      make: (r) => _envR(r)._readState(r, r.uint()).vm,
      write: (w, o) {
        w.ref(o.registry);
        w.ref(o.globals);
        w.ref(o.mainThread);
        w.map(o.typeMetatables, w.str, w.ref);
        w.boolean(o.captureTracebacks);
      },
      read: (r, o) {
        void same(Object got, Object want, String what) {
          if (!identical(got, want)) {
            throw SnapError('$what is not the boot one');
          }
        }

        same(r.ref<LuaTable>(), o.registry, 'the registry');
        same(r.ref<LuaTable>(), o.globals, 'the globals');
        same(r.ref<LuaThread>(), o.mainThread, 'the main thread');
        r.mapInto(o.typeMetatables, r.str, r.ref<LuaTable>);
        o.captureTracebacks = r.boolean();
      },
    );
}
