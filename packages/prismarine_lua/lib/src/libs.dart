// Ported from Lua 5.2.3 linit.c (MIT, see LICENSE-lua).

import 'lib/base.dart';
import 'lib/bit32.dart';
import 'lib/coroutine.dart';
import 'lib/dblib.dart';
import 'lib/io.dart';
import 'lib/os.dart';
import 'lib/package.dart';
import 'lib/string.dart';
import 'lib/table.dart';
import 'state.dart';
import 'table.dart';

/// Opens the standard libraries into the globals of [vm] in the order of
/// `luaL_openlibs` and stores each in `package.loaded`. Then applies the
/// patches of the configuration.
void openLibs(LuaVm vm) {
  final loaded = LuaTable();
  vm.registry.set('_LOADED', loaded);
  openBase(vm);
  loaded.set('_G', vm.globals);
  void lib(String name, LuaTable t) {
    loaded.set(name, t);
    vm.globals.set(name, t);
  }

  lib('package', openPackage(vm));
  lib('coroutine', coroutineLibrary());
  lib('table', openTable(LuaTable(0, 7)));
  lib('io', openIo(vm, LuaTable(0, 11)));
  lib('os', openOs(LuaTable(0, 11)));
  final string = openString(vm, LuaTable(0, 14));
  lib('string', string);
  lib('bit32', openBit32(LuaTable(0, 12)));
  lib('math', vm.config.openMath(vm, LuaTable(0, 28)));
  lib('debug', openDebug(LuaTable(0, 16)));
  vm.config.patchLibs(vm);
}
