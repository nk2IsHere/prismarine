// Lua values in Dart, after lobject.h. nil is `null`, a boolean is a `bool`
// and a number is a `double`. A string is a `String` whose code units are
// bytes. Collectable objects extend [LuaObject].

import 'table.dart';

int _nextId = 1;

/// The id of the next [LuaObject]. Snapshots save and restore it.
int get luaNextId => _nextId;
set luaNextId(int v) => _nextId = v;

/// Receives every [LuaObject] made while it is set. A state's boot objects
/// are collected this way, and a snapshot refers to them by creation order.
List<LuaObject>? luaCollect;

/// A collectable Lua object. [id] takes the place of its address where Lua
/// hashes a pointer, as for a table key, or prints it, as `tostring` does.
abstract class LuaObject {
  LuaObject() {
    luaCollect?.add(this);
  }

  /// Set once at creation. A snapshot's restore gives the object the id of
  /// the snapshot.
  int id = _nextId++;
}

/// Closures and natives.
abstract class LuaFunction extends LuaObject {}

/// A Lua thread, which is a coroutine or a script thread of the host.
abstract class LuaThreadBase extends LuaObject {}

/// Full userdata, such as an object of the host or the handle `io.stdout`.
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

/// `luaV_rawequalobj`. Numbers compare by value, strings by content and
/// objects by identity.
bool luaRawEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is double) return b is double && a == b;
  if (a is String) return b is String && a == b;
  if (a is bool) return b is bool && a == b;
  return false;
}
