// What the lint knows about `dart:` members: the ones that never allocate
// and the ones that always do (tools/lint/alloc_sdk.txt, a verdict and a
// member per line). A member not listed is reported as kind `sdk`.
import 'dart:io';

class SdkVerdicts {
  SdkVerdicts(this._byMember);
  final Map<String, String> _byMember;

  /// `<verdict> <library>::<Class>.<member>` lines; `#` starts a comment.
  /// Verdicts: `ok`, or the kind the call counts as.
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

  /// The verdict for a member id, looked up on the classes the receiver's
  /// type implements ([onClasses], nearest first: `List.any` before
  /// `Iterable.any`, and `List.add` covers a typed list's), then on the
  /// declaring class.
  String? of(String member, String name, Iterable<String> onClasses) {
    for (final c in onClasses) {
      final v = _byMember['$c.$name'];
      if (v != null) return v;
    }
    return _byMember[member];
  }
}
