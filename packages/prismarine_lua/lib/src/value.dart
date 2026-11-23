// Lua values in Dart (lobject.h). nil is `null`, booleans are `bool`, numbers
// are `double`s holding float32 values, strings are `String`s whose code units
// are bytes; collectable objects extend [LuaObject].

import 'table.dart';

int _nextId = 1;

/// The id the next [LuaObject] gets (snapshots save and restore it).
int get luaNextId => _nextId;
set luaNextId(int v) => _nextId = v;

/// While set, every [LuaObject] made is added to it (a Lua state's boot
/// objects, which a snapshot names by their creation order).
List<LuaObject>? luaCollect;

/// A collectable Lua object. [id] stands in for its address wherever Lua
/// hashes pointers (table keys) or prints them (`tostring`).
abstract class LuaObject {
  LuaObject() {
    luaCollect?.add(this);
  }

  /// Set once at creation; a snapshot's restore gives the object its id
  /// from the snapshot.
  int id = _nextId++;
}

/// Closures and natives.
abstract class LuaFunction extends LuaObject {}

/// Lua threads (coroutines and script threads).
abstract class LuaThreadBase extends LuaObject {}

/// Full userdata: engine objects and library handles (`io.stdout`).
class LuaUserdata extends LuaObject {
  LuaUserdata([this.payload]);
  Object? payload;
  LuaTable? metatable;
  Object? userValue;
}

/// `lua_typename` of a value.
String luaTypeName(Object? v) => switch (v) {
  null => 'nil',
  bool() => 'boolean',
  double() => 'number',
  String() => 'string',
  LuaTable() => 'table',
  LuaFunction() => 'function',
  LuaThreadBase() => 'thread',
  LuaUserdata() => 'userdata',
  _ => throw StateError('not a Lua value: ${v.runtimeType}'),
};

/// `luaV_rawequalobj`: same type and value (numbers by value, strings by
/// content, objects by identity).
bool luaRawEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is double) return b is double && a == b;
  if (a is String) return b is String && a == b;
  if (a is bool) return b is bool && a == b;
  return false;
}
