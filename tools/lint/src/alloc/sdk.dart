// The verdicts of the lint on `dart:` members, the ones that do not allocate
// and the ones that always do. tools/lint/alloc_sdk.txt holds a verdict and a
// member per line. A member not listed is reported as kind `sdk`.
import 'dart:io';

class SdkVerdicts {
  SdkVerdicts(this._byMember);
  final Map<String, String> _byMember;

  /// Reads lines of the form `<verdict> <library>::<Class>.<member>` from
  /// [path], where `#` starts a comment. A verdict is `ok` or the kind of the
  /// call.
  static SdkVerdicts read(String path) {
    final out = <String, String>{};
    for (final raw in File(path).readAsLinesSync()) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) continue;
      final at = line.indexOf(' ');
      if (at < 0) throw FormatException('alloc_sdk.txt: "$raw"');
      out[line.substring(at + 1).trim()] = line.substring(0, at);
    }
    return SdkVerdicts(out);
  }

  /// Returns the verdict for the [member] id with the [name], looked up on
  /// the classes [onClasses] that the type of the receiver implements and
  /// then on the declaring class. [onClasses] is nearest first, `List.any`
  /// before `Iterable.any`. `List.add` covers the add of a typed list.
  String? of(String member, String name, Iterable<String> onClasses) {
    for (final c in onClasses) {
      final v = _byMember['$c.$name'];
      if (v != null) return v;
    }
    return _byMember[member];
  }
}
