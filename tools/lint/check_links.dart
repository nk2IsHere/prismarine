// check_links reports Markdown links that point at missing files.
//
//   dart tools/lint/check_links.dart [<file or dir>...]
//
// With no arguments it checks the `links` list of tools/lint/config.yaml,
// which is CLAUDE.md, docs/memory and docs/areas by default. In each
// Markdown file it checks relative `[text](path)` and `[text](path#anchor)`
// links, without the anchor itself, and `[[name]]` wikilinks, which must
// point at a file in the same directory. Links with a scheme, such as https
// or mailto, and pure anchors are skipped, as is anything inside backticks.
//
// The exit code is 0 when clean and 1 for dangling links.
import 'dart:io';

import 'src/config.dart';
import 'src/scope.dart';

final _link = RegExp(r'\[[^\]]*\]\(([^)\s]+)\)');
final _wiki = RegExp(r'\[\[([^\]]+)\]\]');
final _code = RegExp(r'`[^`]*`');

void main(List<String> args) {
  final targets = args.isEmpty ? LintConfig.of(repoRoot()).links : args;
  final files = <File>[];
  for (final t in targets) {
    if (FileSystemEntity.isDirectorySync(t)) {
      files.addAll(
        Directory(t)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.md')),
      );
    } else if (File(t).existsSync()) {
      files.add(File(t));
    } else {
      stderr.writeln('check_links: no such file or directory: $t');
      exitCode = 1;
    }
  }
  var bad = 0;
  for (final f in files) {
    final dir = f.parent.path;
    final lines = f.readAsLinesSync();
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      if (raw.trimLeft().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      final line = raw.replaceAll(_code, '');
      for (final m in _link.allMatches(line)) {
        final target = m.group(1)!;
        if (target.startsWith('#') || RegExp(r'^[a-z]+:').hasMatch(target)) {
          continue;
        }
        final path = Uri.decodeComponent(target.split('#').first);
        if (path.isEmpty) continue;
        if (!FileSystemEntity.isFileSync('$dir/$path') &&
            !FileSystemEntity.isDirectorySync('$dir/$path')) {
          stdout.writeln('${f.path}:${i + 1}: dangling link $target');
          bad++;
        }
      }
      for (final m in _wiki.allMatches(line)) {
        final name = m.group(1)!;
        if (!File('$dir/$name.md').existsSync()) {
          stdout.writeln('${f.path}:${i + 1}: dangling wikilink [[$name]]');
          bad++;
        }
      }
    }
  }
  if (bad > 0) {
    stdout.writeln(
      'check_links: $bad dangling link(s) in ${files.length} files',
    );
    exitCode = 1;
  } else {
    stdout.writeln('check_links: ${files.length} files, no dangling links');
  }
}
