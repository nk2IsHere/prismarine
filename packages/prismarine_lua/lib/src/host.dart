// The host side of a Lua VM.

import 'dart:typed_data';

/// The output, logs, resources and clocks that a VM gets from its host.
abstract class LuaHost {
  /// Writes [s] to the standard output of `print` and `io.write`.
  void write(String s);

  /// Writes [message] to the diagnostic [channel].
  void log(String channel, String message);

  /// Returns the resource [name] for `require`, `dofile` and `loadfile`, or
  /// null.
  Uint8List? readResource(String name);

  /// The seconds of `os.clock`.
  double clock();

  /// The seconds of `os.time`.
  int time();
}

/// A host that collects output in memory and has the [resources] given.
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
