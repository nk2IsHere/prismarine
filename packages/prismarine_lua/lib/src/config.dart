// The build configuration of a Lua VM, as luaconf.h and the C library give
// it to a C build of Lua.

import 'lib/math.dart' show openStandardMath;
import 'runtime.dart';
import 'state.dart';
import 'table.dart';

/// The type of `lua_Number` and the precision of its operations.
enum LuaNumberMode {
  /// IEEE double numbers.
  float64,

  /// Float numbers. Each operation is computed in double and its result is
  /// rounded to float once, as in a build on x87 code.
  float32,

  /// Float numbers. Each operation is a single-precision operation, as in a
  /// build on SSE code. A NaN operand passes through to the result.
  float32Single;

  /// True for the two float modes.
  bool get isFloat32 => this != float64;
}

/// The configuration of a [LuaVm]. Every member has a default. A class or an
/// enum mixes it in and overrides the members it changes.
abstract mixin class LuaConfig {
  /// The number mode. All VMs of an isolate share one mode.
  LuaNumberMode get numberMode => LuaNumberMode.float64;

  /// The width of `lua_Integer` is 64 bits, or 32 bits when false.
  bool get integer64 => true;

  /// The `size_t` width in the header of the binary chunks that `load`
  /// accepts.
  int get chunkSizeT => 8;

  /// The C library under the Lua build.
  LuaCRuntime get runtime => const LuaCRuntime();

  /// `==` of two values of different types calls the `__eq` metamethod of
  /// the first operand, else of the second, and is false without one.
  bool get mixedTypeEquality => false;

  /// The message of `loadfile` and `dofile` for a file that the host does
  /// not have.
  String missingFileText(String name) =>
      'cannot open $name: No such file or directory';

  /// Fills the `math` library table [t] of [vm].
  LuaTable openMath(LuaVm vm, LuaTable t) => openStandardMath(vm, t);

  /// Changes the libraries of [vm] after the standard libraries are open.
  void patchLibs(LuaVm vm) {}
}

/// The default configuration.
class LuaDefaultConfig with LuaConfig {
  const LuaDefaultConfig();
}
