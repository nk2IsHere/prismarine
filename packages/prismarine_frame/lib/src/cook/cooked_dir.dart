import 'dart:convert';
import 'dart:io';

import 'cooked.dart';

/// The cooked cache that the pulled passes of a renderer draw from for
/// [content]. `PRISMARINE_PULLED`, else `MCSM_PULLED`, gives a directory, or
/// `off` for none. Without either, the cache is `<content>/cooked` when it
/// holds its compiled programs and every scene's `cooked.json` is of
/// [cookVersion], else null. A stale or partial cache could leave a row
/// undrawable.
String? pulledDir(String content, {Map<String, String>? environment}) {
  final vars = environment ?? Platform.environment;
  final env = vars['PRISMARINE_PULLED'] ?? vars['MCSM_PULLED'];
  if (env == 'off') return null;
  if (env != null && env.isNotEmpty) return env;
  final dir = Directory('$content/cooked');
  if (!Directory('${dir.path}/shaders/bundle').existsSync()) return null;
  var scenes = 0;
  for (final d in dir.listSync().whereType<Directory>()) {
    final f = File('${d.path}/cooked.json');
    if (!f.existsSync()) continue;
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map || j['version'] != cookVersion) return null;
    scenes++;
  }
  return scenes == 0 ? null : dir.path;
}
