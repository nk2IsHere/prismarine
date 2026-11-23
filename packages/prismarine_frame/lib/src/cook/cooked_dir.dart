import 'dart:convert';
import 'dart:io';

import 'cooked.dart';

/// The cooked cache the renderer's pulled passes draw from for [slice]
/// (the own-renderer design, R0): `MCSM_PULLED` naming a directory, or
/// `off` for none; else the slice's own `<slice>/cooked` when it holds its
/// compiled programs and every scene's `cooked.json` is of [cookVersion]
/// (a stale or partial cache could leave a cascade row undrawable). The
/// builder's rows and the runner's pulled passes go together by it.
String? pulledDir(String slice, {Map<String, String>? environment}) {
  final env = (environment ?? Platform.environment)['MCSM_PULLED'];
  if (env == 'off') return null;
  if (env != null && env.isNotEmpty) return env;
  final dir = Directory('$slice/cooked');
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
