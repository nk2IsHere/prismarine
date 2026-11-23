// A minimal form of Lua 5.2.3 liolib.c (MIT, see LICENSE-lua). Output goes
// to the host, and no file opens.

import '../state.dart';
import '../table.dart';
import '../value.dart';

/// True when [o] is a file handle of the io library, stdin, stdout or
/// stderr. A snapshot keeps the payload that a fresh state made.
bool luaIsIoHandle(Object? o) => o is _File;

class _File {
  _File(this.name, this.out);
  final String name;
  final void Function(LuaVm vm, String s)? out;
  bool closed = false;
}

/// `luaopen_io` into [t] with the io functions, stdin, stdout, stderr and
/// the file methods.
LuaTable openIo(LuaVm vm, LuaTable t) {
  final mt = LuaTable();
  final methods = LuaTable();
  LuaUserdata file(String name, void Function(LuaVm, String)? out) =>
      LuaUserdata(_File(name, out))..metatable = mt;
  final stdin = file('stdin', null);
  final stdout = file('stdout', (vm, s) => vm.host.write(s));
  final stderr = file('stderr', (vm, s) => vm.host.log('stderr', s));
  var output = stdout;

  _File toFile(LuaThread L, int i) {
    final u = L.arg(i);
    if (u is LuaUserdata && u.payload is _File) return u.payload as _File;
    L.typeErrorArg(i, 'FILE*');
  }

  int write(LuaThread L, LuaUserdata f, int first) {
    final ff = f.payload as _File;
    final sb = StringBuffer();
    for (var i = first; i <= L.getTop(); i++) {
      final v = L.arg(i);
      sb.write(v is double ? L.vm.runtime.numberToString(v) : L.checkString(i));
    }
    ff.out?.call(L.vm, sb.toString());
    L.push(f);
    return 1;
  }

  int noFile(LuaThread L, String name) {
    L.push(null);
    L.push('$name: No such file or directory');
    L.push(2.0);
    return 3;
  }

  for (final (name, f) in <(String, LuaCFunction)>[
    (
      'close',
      (L) {
        L.push(true);
        return 1;
      },
    ),
    (
      'flush',
      (L) {
        L.push(true);
        return 1;
      },
    ),
    (
      'lines',
      (L) {
        if (L.arg(1) == null) {
          L.push(
            LuaNative((L) {
              L.push(null);
              return 1;
            }),
          );
          return 1;
        }
        final n = L.checkString(1);
        L.luaError('$n: No such file or directory');
      },
    ),
    (
      'read',
      (L) {
        L.push(null);
        return 1;
      },
    ),
    (
      'seek',
      (L) {
        toFile(L, 1);
        L.push(0.0);
        return 1;
      },
    ),
    (
      'setvbuf',
      (L) {
        toFile(L, 1);
        L.push(true);
        return 1;
      },
    ),
    (
      'write',
      (L) {
        toFile(L, 1);
        return write(L, L.arg(1) as LuaUserdata, 2);
      },
    ),
  ]) {
    methods.set(name, LuaNative(f, name));
  }
  mt
    ..set('__index', methods)
    ..set(
      '__tostring',
      LuaNative((L) {
        final f = toFile(L, 1);
        L.push(
          f.closed ? 'file (closed)' : 'file (${L.pointerText(L.arg(1))})',
        );
        return 1;
      }, '__tostring'),
    );
  for (final (name, f) in <(String, LuaCFunction)>[
    (
      'close',
      (L) {
        L.push(true);
        return 1;
      },
    ),
    (
      'flush',
      (L) {
        L.push(true);
        return 1;
      },
    ),
    (
      'input',
      (L) {
        L.push(stdin);
        return 1;
      },
    ),
    (
      'lines',
      (L) {
        final n = L.optString(1, null);
        if (n == null) {
          L.push(
            LuaNative((L) {
              L.push(null);
              return 1;
            }),
          );
          return 1;
        }
        L.luaError('$n: No such file or directory');
      },
    ),
    ('open', (L) => noFile(L, L.checkString(1))),
    (
      'output',
      (L) {
        final v = L.arg(1);
        if (v is LuaUserdata && v.payload is _File) output = v;
        L.push(output);
        return 1;
      },
    ),
    ('popen', (L) => noFile(L, L.checkString(1))),
    (
      'read',
      (L) {
        L.push(null);
        return 1;
      },
    ),
    ('tmpfile', (L) => noFile(L, 'tmpfile')),
    (
      'type',
      (L) {
        L.checkAny(1);
        final v = L.arg(1);
        L.push(
          v is LuaUserdata && v.payload is _File
              ? ((v.payload as _File).closed ? 'closed file' : 'file')
              : null,
        );
        return 1;
      },
    ),
    ('write', (L) => write(L, output, 1)),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  t
    ..set('stdin', stdin)
    ..set('stdout', stdout)
    ..set('stderr', stderr);
  return t;
}
