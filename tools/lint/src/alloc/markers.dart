// The marker comments of the allocation lint. `// alloc: <reason>` accepts a
// place. `// alloc-cold: <reason>` marks a function that a steady frame does
// not run. `// alloc-setup: <reason>` marks a function that runs once, with
// only the closures that it makes running per frame.
import 'program.dart';

final _accept = RegExp(r'//\s*alloc:\s*(\S.*)$');
final _cold = RegExp(r'//\s*alloc-cold:\s*(\S.*)$');
final _setup = RegExp(r'//\s*alloc-setup:\s*(\S.*)$');

class Markers {
  Markers(SourceFile file) : _lines = file.text.split('\n');
  final List<String> _lines;

  static final _byFile = <String, Markers>{};
  static Markers of(SourceFile file) => _byFile[file.path] ??= Markers(file);

  /// Returns the reason on [line], counted from 1, or alone on the line above
  /// it.
  String? accepted(int line) => _on(_accept, line);

  /// Returns the reason that a declaration starting on [line] is cold. The
  /// reason is on that line or in the comment lines right above it. Any
  /// comment line of the block counts, and the marker need not be below a doc
  /// comment or an annotation.
  String? cold(int line) => _above(_cold, line);

  /// Returns the reason that a declaration starting on [line] is setup. It
  /// runs once, and only the closures that it makes run per frame.
  String? setup(int line) => _above(_setup, line);

  String? _above(RegExp marker, int line) {
    final here = _match(marker, line);
    if (here != null) return here;
    for (var l = line - 1; l >= 1; l--) {
      final text = _lines[l - 1].trim();
      if (!(text.startsWith('//') || text.startsWith('@'))) break;
      final m = marker.firstMatch(text);
      if (m != null) return m[1];
    }
    return null;
  }

  String? _on(RegExp marker, int line) {
    final here = _match(marker, line);
    if (here != null) return here;
    if (line < 2) return null;
    final above = _lines[line - 2].trim();
    if (!above.startsWith('//')) return null;
    return marker.firstMatch(above)?[1];
  }

  String? _match(RegExp marker, int line) {
    if (line < 1 || line > _lines.length) return null;
    return marker.firstMatch(_lines[line - 1])?[1];
  }
}
