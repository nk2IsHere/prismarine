// The settings of the lints for one repository. The file is
// tools/lint/config.yaml at the repository root, or the file that
// $PRISMARINE_LINT_CONFIG gives. A repository that runs these lints from a
// pinned checkout keeps its own config.
import 'dart:io';

import 'package:yaml/yaml.dart';

class LintConfig {
  LintConfig._(this.root, this._y);

  /// The repository that the lints check.
  final String root;
  final YamlMap _y;

  static LintConfig? _cached;

  /// Returns the config of the repository at [root], read once a process.
  static LintConfig of(String root) {
    final c = _cached;
    if (c != null && c.root == root) return c;
    final path =
        Platform.environment['PRISMARINE_LINT_CONFIG'] ??
        '$root/tools/lint/config.yaml';
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('lint: no config at $path');
      exit(2);
    }
    final y = loadYaml(f.readAsStringSync());
    return _cached = LintConfig._(root, y is YamlMap ? y : YamlMap());
  }

  /// Parses a config from YAML text.
  factory LintConfig.parse(String root, String yaml) {
    final y = loadYaml(yaml);
    return LintConfig._(root, y is YamlMap ? y : YamlMap());
  }

  Object? _at(String path) {
    Object? v = _y;
    for (final k in path.split('.')) {
      if (v is! Map) return null;
      v = v[k];
    }
    return v;
  }

  String _str(String path, String fallback) =>
      _at(path) is String ? _at(path) as String : fallback;

  List<String> _strs(String path, List<String> fallback) {
    final v = _at(path);
    return v is List ? [for (final e in v) '$e'] : fallback;
  }

  /// The directories with the code that the lints check, each with a
  /// trailing slash.
  List<String> get codeRoots =>
      _strs('code_roots', ['packages/', 'apps/', 'tools/']);

  /// The vendored files outside a third_party/ directory.
  Set<String> get vendoredFiles => _strs('vendored_files', []).toSet();

  /// The paths that code_shape checks for size only. The files of the lint
  /// quote the patterns it looks for.
  List<String> get commentCheckExempt =>
      _strs('comment_check_exempt', ['tools/lint/']);

  /// The directories with Dart code outside any package.
  List<String> get looseDirs => _strs('loose_dirs', ['tools/lint']);

  /// The extra cargo arguments of each crate that builds for one target only.
  Map<String, List<String>> get crateArgs {
    final v = _at('crate_args');
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        '${e.key}': [for (final a in e.value as List) '$a'],
    };
  }

  String baseline(String lint) => _str('baselines.$lint', switch (lint) {
    'code_shape' => 'tools/lint/baseline.json',
    _ => 'tools/lint/${lint}_baseline.json',
  });

  String get allocRoots => _str('alloc.roots', 'tools/lint/alloc_roots.txt');
  String get allocSdk => _str('alloc.sdk', 'tools/lint/alloc_sdk.txt');

  /// The package directories that the allocation lint resolves, or null for
  /// the members of the workspace.
  List<String>? get allocPackages {
    final v = _at('alloc.packages');
    return v is List ? [for (final e in v) '$e'] : null;
  }

  /// The environment variable with the path of the private repo.
  String get privateEnv => _str('privacy.private_env', 'PRISMARINE_PRIVATE');

  String get privacyPending =>
      _str('privacy.pending', 'tools/lint/privacy_pending.txt');

  /// The files and directories that check_links reads without arguments.
  List<String> get links =>
      _strs('links', ['CLAUDE.md', 'docs/memory', 'docs/areas']);

  /// The doc folders with one file per entry that docs_index indexes.
  List<Map<Object?, Object?>> get docsIndex {
    final v = _at('docs_index');
    return v is List ? [for (final e in v) e as Map] : const [];
  }

  /// The code_shape rule sets of this repository with their settings, by
  /// the key of each set in src/rule_sets.dart.
  Map<String, Map<Object?, Object?>> get ruleSets {
    final v = _at('code_shape.rule_sets');
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        '${e.key}': e.value is Map ? e.value as Map : const {},
    };
  }

  /// The agent and branch words of this repository. A comment with one of
  /// them counts as history.
  List<String> get historyNames => _strs('code_shape.history.names', []);

  /// The extra patterns of pointers into plans or reports.
  List<String> get historyPointers => _strs('code_shape.history.pointers', []);
}
