// The files that the code lints check are our own code under the code roots
// of the config, as tracked by git. The roots are packages/, apps/ and
// tools/ by default.
import 'dart:io';

import 'config.dart';
import 'lexer.dart';

// Returns the config of the repository that the lint checks.
LintConfig get _config => LintConfig.of(repoRoot());

List<String> get codeRoots => _config.codeRoots;

// The vendored or upstream-derived files outside a third_party/ directory.
Set<String> get vendoredFiles => _config.vendoredFiles;

// The rules and tests of the lint quote the patterns that they search. Its
// files are left out of the comment and string checks but not the size check.
List<String> get commentCheckExempt => _config.commentCheckExempt;

// The `flutter create` runner scaffolding of an app or a tool app.
final _scaffold = RegExp(
  r'^(apps|tools)/[^/]+/(macos|linux|windows|ios|android|web)/',
);

final _generatedHeader = RegExp(
  r'^\s*(//|#|/?\*|--)\s*(GENERATED|Generated (by|from)|DO NOT EDIT)',
  caseSensitive: true,
);

/// Returns the reason that [path] is outside the lint, or null when it is in
/// scope. Tests [text] for a generated header only when it is given.
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

/// Returns true when [text] is generated. A generated file says so in a
/// comment within its first five lines.
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

/// Returns the repository root, the top of the git work tree that contains
/// the cwd.
String repoRoot() {
  if (_root case final r?) return r;
  final r = Process.runSync('git', ['rev-parse', '--show-toplevel']);
  if (r.exitCode != 0) {
    stderr.writeln('not inside a git work tree');
    exit(2);
  }
  return _root = (r.stdout as String).trim();
}

/// Returns the files under the code roots that git tracks or would track,
/// relative to [root]. New files not yet added count. Ignored files do not.
List<String> trackedCodeFiles(String root) =>
    _listed(root, (p) => excludedBecause(p) == null);

/// Returns the files under the code roots that are not source files and
/// that the lint does not read, such as JSON files and compute shaders.
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

/// Returns the package of [path], the nearest directory among [packageDirs]
/// with a pubspec.yaml or Cargo.toml, else its first two path segments.
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

/// Returns the directories relative to [root] that hold a pubspec.yaml or
/// Cargo.toml.
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
