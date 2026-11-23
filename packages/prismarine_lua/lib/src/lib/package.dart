// Ported from Lua 5.2.3 loadlib.c (MIT, see LICENSE-lua). Modules are
// resources of the host.

import '../state.dart';
import '../table.dart';
import '../value.dart';
import 'base.dart' show loadBytes;

const _path =
    '/usr/local/share/lua/5.2/?.lua;/usr/local/share/lua/5.2/?/init.lua;'
    '/usr/local/lib/lua/5.2/?.lua;/usr/local/lib/lua/5.2/?/init.lua;./?.lua';
const _cpath =
    '/usr/local/lib/lua/5.2/?.so;/usr/local/lib/lua/5.2/loadall.so;./?.so';

LuaTable _getSubTable(LuaTable t, String name) {
  final v = t.get(name);
  if (v is LuaTable) return v;
  final n = LuaTable();
  t.set(name, n);
  return n;
}

int _searcherPreload(LuaThread L) {
  final name = L.checkString(1);
  final v = _getSubTable(L.vm.registry, '_PRELOAD').get(name);
  L.push(v ?? "\n\tno field package.preload['$name']");
  return 1;
}

List<String> _templates(String path) =>
    path.split(';').where((t) => t.isNotEmpty).toList();

/// `searcher_Lua` over the resources of the host.
LuaCFunction _searcherLua(LuaTable package) => (L) {
  final name = L.checkString(1);
  final path = package.get('path');
  if (path is! String) L.luaError("'package.path' must be a string");
  final msg = StringBuffer();
  final file = name.replaceAll('.', '/');
  for (final t in _templates(path)) {
    final fname = t.replaceAll('?', file);
    final bytes = L.vm.host.readResource(fname);
    if (bytes != null) {
      final (f, err) = loadBytes(L, bytes, '@$fname', null);
      if (f == null) {
        L.luaError("error loading module '$name' from file '$fname':\n\t$err");
      }
      L.push(f);
      L.push(fname);
      return 2;
    }
    msg.write("\n\tno file '$fname'");
  }
  L.push(msg.toString());
  return 1;
};

/// `searcher_C` and `searcher_Croot`. No C module loads, and the searchers
/// give their messages.
LuaCFunction _searcherC(LuaTable package, {required bool root}) => (L) {
  var name = L.checkString(1);
  if (root) {
    final dot = name.indexOf('.');
    if (dot < 0) return 0;
    name = name.substring(0, dot);
  }
  final cpath = package.get('cpath');
  if (cpath is! String) L.luaError("'package.cpath' must be a string");
  final file = name.replaceAll('.', '/');
  L.push(
    [
      for (final t in _templates(cpath))
        "\n\tno file '${t.replaceAll('?', file)}'",
    ].join(),
  );
  return 1;
};

LuaCFunction _require(LuaTable package) => (L) {
  final name = L.checkString(1);
  L.setTop(1);
  final loaded = _getSubTable(L.vm.registry, '_LOADED');
  final have = loaded.get(name);
  if (have != null && have != false) {
    L.push(have);
    return 1;
  }
  final searchers = package.get('searchers');
  if (searchers is! LuaTable) L.luaError("'package.searchers' must be a table");
  final msg = StringBuffer();
  for (var i = 1; ; i++) {
    final s = searchers.getInt(i);
    if (s == null) L.luaError("module '$name' not found:$msg");
    L.push(s);
    L.push(name);
    L.call(1, 2);
    final loader = L.arg(-2);
    if (loader is LuaFunction) break;
    final m = L.arg(-2);
    if (m is String || m is double) msg.write(L.toStr(-2));
    L.pop(2);
  }
  // The loader and its extra value are on the top. Calls
  // loader(name, extra).
  L.push(name);
  L.insert(-2);
  L.call(2, 1);
  final r = L.arg(-1);
  if (r != null) loaded.set(name, r);
  if (loaded.get(name) == null) loaded.set(name, true);
  L.push(loaded.get(name));
  return 1;
};

/// `luaopen_package`. Returns the `package` table and sets `require` in the
/// globals.
LuaTable openPackage(LuaVm vm) {
  final package = LuaTable(0, 2)
    ..set(
      'loadlib',
      LuaNative((L) {
        L.push(null);
        L.push('dynamic libraries not enabled; check your Lua installation');
        L.push('absent');
        return 3;
      }, 'loadlib'),
    )
    ..set(
      'searchpath',
      LuaNative((L) {
        final name = L
            .checkString(1)
            .replaceAll(L.optString(3, '.')!, L.optString(4, '/')!);
        final msg = StringBuffer();
        for (final t in _templates(L.checkString(2))) {
          final fname = t.replaceAll('?', name);
          if (L.vm.host.readResource(fname) != null) {
            L.push(fname);
            return 1;
          }
          msg.write("\n\tno file '$fname'");
        }
        L.push(null);
        L.push(msg.toString());
        return 2;
      }, 'searchpath'),
    );
  final searchers = LuaTable(4, 0)
    ..setInt(1, LuaNative(_searcherPreload, 'searcher_preload'))
    ..setInt(2, LuaNative(_searcherLua(package), 'searcher_Lua'))
    ..setInt(3, LuaNative(_searcherC(package, root: false), 'searcher_C'))
    ..setInt(4, LuaNative(_searcherC(package, root: true), 'searcher_Croot'));
  package
    ..set('searchers', searchers)
    ..set('path', _path)
    ..set('cpath', _cpath)
    ..set('config', '/\n;\n?\n!\n-\n')
    ..set('loaded', _getSubTable(vm.registry, '_LOADED'))
    ..set('preload', _getSubTable(vm.registry, '_PRELOAD'));
  vm.globals.set('require', LuaNative(_require(package), 'require'));
  return package;
}
