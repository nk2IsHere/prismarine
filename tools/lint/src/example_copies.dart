// The examples in Markdown files that copy a Dart file. A fenced `dart` block
// whose line before it ends in a link to a `.dart` file holds the whole text of
// that file. The analyzer checks the file and this check keeps the copy equal.
import 'dart:io';

final _dartLink = RegExp(r'\]\(([^)\s#]+\.dart)\):?\s*$');

/// Returns one message per fenced `dart` block in [lines] whose text differs
/// from the Dart file that the line before it links to. [dir] is the
/// directory of the Markdown file and [where] its path in the messages.
List<String> exampleMismatches(
  String where,
  String dir,
  List<String> lines, {
  String? Function(String path) read = _read,
}) {
  final out = <String>[];
  String? linked;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    final target = linked;
    linked = _dartLink.firstMatch(line)?.group(1);
    if (target == null || !line.trimLeft().startsWith('```dart')) continue;
    final block = <String>[];
    var j = i + 1;
    while (j < lines.length && !lines[j].trimLeft().startsWith('```')) {
      block.add(lines[j++]);
    }
    final text = read('$dir/${Uri.decodeComponent(target)}');
    if (text == null) {
      out.add('$where:${i + 1}: no file $target for the example');
    } else if (block.join('\n') != text.trimRight()) {
      out.add('$where:${i + 1}: the example differs from $target');
    }
    i = j;
    linked = null;
  }
  return out;
}

String? _read(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}
