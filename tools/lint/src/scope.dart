// The files that the code lints check are our own code under the code roots
// of the config, as tracked by git. The roots are packages/, apps/ and
// tools/ by default.
import 'dart:io';

import 'config.dart';
import 'lexer.dart';

// The config of the repository that the lint checks.
LintConfig get _config => LintConfig.of(repoRoot());

List<String> get codeRoots => _config.codeRoots;

// Vendored or upstream-derived files that live outside a third_party/ dir.
Set<String> get vendoredFiles => _config.vendoredFiles;

// The lint's own rules and tests quote the patterns they look for, so its
// files are left out of the comment and string checks (not the size check).
List<String> get commentCheckExempt => _config.commentCheckExempt;

// `flutter create` runner scaffolding of an app (or a tool app).
final _scaffold = RegExp(
  r'^(apps|tools)/[^/]+/(macos|linux|windows|ios|android|web)/',
);

final _generatedHeader = RegExp(
  r'^\s*(//|#|/?\*|--)\s*(GENERATED|Generated (by|from)|DO NOT EDIT)',
  caseSensitive: true,
);

/// Why [path] is outside the lint (null when it is in scope). Reads the file
/// for the generated-header test only when [text] is given.
String? excludedBecause(String path, [String? text]) {
  if (!codeRoots.any(path.startsWith)) return 'outside the code roots';
  if (path.split('/').contains('third_party')) return 'third_party';
  if (vendoredFiles.contains(path)) return 'vendored';
  if (_scaffold.hasMatch(path)) return 'runner scaffolding';
  if (path.contains('/golden/')) return 'golden output';
  if (langOf(path) == null) return 'not a source file';
  if (text != null && isGenerated(text)) return 'generated';
  return null;
}

/// A generated file says so in a comment within its first five lines.
bool isGenerated(String text) {
  var n = 0;
  for (final l in text.split('\n')) {
    if (_generatedHeader.hasMatch(l)) return true;
    if (++n == 5) break;
  }
  return false;
}

String? _root;

/// Sets [root] as the repository to check in place of the work tree of the
/// cwd.
void setRepoRoot(String root) => _root = root;

/// The repository root (the top of the git work tree containing the cwd).
String repoRoot() {
  if (_root case final r?) return r;
  final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (r.exitCode != 0) {
    stderr.writeln('not inside a git work tree');
    exit(2);
  }
  return _root = (r.stdout as String).trim();
}

/// Files under the code roots that git tracks or would track (new files not
/// yet added count; ignored ones don't), relative to [root].
List<String> trackedCodeFiles(String root) =>
    _listed(root, (p) => excludedBecause(p) == null);

/// The files under the code roots that the lint does not read since they are
/// no source files, such as JSON files and compute shaders.
List<String> trackedOtherFiles(String root) =>
    _listed(root, (p) => excludedBecause(p) == 'not a source file');

List<String> _listed(String root, bool Function(String) keep) {
  final r = Process.runSync('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    ...codeRoots,
  ], workingDirectory: root);
  return (r.stdout as String)
      .split('\x00')
      .where((p) => p.isNotEmpty && keep(p))
      .where((p) => File('$root/$p').existsSync())
      .toSet()
      .toList()
    ..sort();
}

/// The package a file belongs to: the nearest directory holding a
/// pubspec.yaml or Cargo.toml, else its first two path segments.
String packageOf(String path, Set<String> packageDirs) {
  var dir = path;
  while (true) {
    final slash = dir.lastIndexOf('/');
    if (slash < 0) break;
    dir = dir.substring(0, slash);
    if (packageDirs.contains(dir)) return dir;
  }
  final parts = path.split('/');
  return parts.length > 2 ? '${parts[0]}/${parts[1]}' : parts.first;
}

/// Directories (relative to [root]) that hold a pubspec.yaml or Cargo.toml.
Set<String> packageDirs(String root) {
  final r = Process.runSync('git', [
    'ls-files',
    '-z',
    ...codeRoots,
  ], workingDirectory: root);
  final out = <String>{};
  for (final p in (r.stdout as String).split('\x00')) {
    if (p.endsWith('/pubspec.yaml') || p.endsWith('/Cargo.toml')) {
      if (p.split('/').contains('third_party')) continue;
      out.add(p.substring(0, p.lastIndexOf('/')));
    }
  }
  return out;
}
