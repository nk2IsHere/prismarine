// check_links: reports Markdown links that point at files which don't exist.
//
//   dart tools/lint/check_links.dart [<file or dir>...]
//
// With no arguments it checks the `links` list of tools/lint/config.yaml,
// which is CLAUDE.md, docs/memory and docs/areas by default. For each
// Markdown file it checks relative `[text](path)` and `[text](path#anchor)`
// links (the anchor itself is not checked) and `[[name]]` wikilinks, which
// must name a file in the same directory. Links with a scheme (https:, mailto:)
// and pure anchors are skipped, as is anything inside backticks. A fenced
// `dart` block whose line before it ends in a link to a `.dart` file must hold
// the text of that file (src/example_copies.dart). A directory is read without
// its `.dart_tool`, `build`, `target` and `third_party` directories.
//
// Exit codes: 0 clean, 1 dangling links found.
import 'dart:io';

import 'src/config.dart';
import 'src/example_copies.dart';
import 'src/scope.dart';

final _link = RegExp(r'\[[^\]]*\]\(([^)\s]+)\)');
final _wiki = RegExp(r'\[\[([^\]]+)\]\]');
final _code = RegExp(r'`[^`]*`');

void main(List<String> args) {
  final targets = args.isEmpty ? LintConfig.of(repoRoot()).links : args;
  final files = <File>[];
  for (final t in targets) {
    if (FileSystemEntity.isDirectorySync(t)) {
      files.addAll(_markdown(Directory(t)));
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
    for (final m in exampleMismatches(f.path, dir, lines)) {
      stdout.writeln(m);
      bad++;
    }
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
      'check_links: $bad dangling link(s) or changed examples in '
      '${files.length} files',
    );
    exitCode = 1;
  } else {
    stdout.writeln('check_links: ${files.length} files, no dangling links');
  }
}

const _skipped = {'.dart_tool', 'build', 'target', 'third_party'};

/// The Markdown files under [dir], outside the [_skipped] directories.
Iterable<File> _markdown(Directory dir) sync* {
  for (final e in dir.listSync()) {
    if (e is Directory) {
      if (!_skipped.contains(
        e.uri.pathSegments[e.uri.pathSegments.length - 2],
      )) {
        yield* _markdown(e);
      }
    } else if (e is File && e.path.endsWith('.md')) {
      yield e;
    }
  }
}
