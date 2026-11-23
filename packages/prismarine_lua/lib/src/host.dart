// The host side of a Lua VM.

import 'dart:typed_data';

/// The engine side of the runtime: output, logs, resources, clock.
abstract class LuaHost {
  /// Standard output (stock `print`, `io.write`).
  void write(String s);

  /// Diagnostic channels: `ScriptError`, `print` (the exe's no-op print).
  void log(String channel, String message);

  /// A script resource by name (`require`, `dofile`, `loadfile`), or null.
  Uint8List? readResource(String name);

  /// `os.clock` seconds and `os.time` seconds.
  double clock();
  int time();
}

/// A host that collects output in memory; resources come from [resources].
class MemoryLuaHost implements LuaHost {
  MemoryLuaHost({Map<String, Uint8List>? resources})
    : resources = resources ?? {};
  final StringBuffer out = StringBuffer();
  final logs = <(String, String)>[];
  final Map<String, Uint8List> resources;
  double clockValue = 0;
  int timeValue = 0;

  @override
  void write(String s) => out.write(s);
  @override
  void log(String channel, String message) => logs.add((channel, message));
  @override
  Uint8List? readResource(String name) => resources[name];
  @override
  double clock() => clockValue;
  @override
  int time() => timeValue;
}
