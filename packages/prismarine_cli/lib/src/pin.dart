import 'dart:io';

import 'ui.dart';

/// A git repository whose pubspecs and Cargo.toml files depend on prismarine
/// as a git dependency, pinned to one commit. The dependencies name a URL
/// that each computer maps to a real repository with git's
/// `url.<source>.insteadOf`, such as `https://prismarine.invalid/prismarine.git`.
class PinTree {
  PinTree._(this.root, this.url, this.pubspecs, this.crates);

  /// Finds the repository of [dir] and the prismarine URL of its pubspecs.
  /// Throws a [Failure] outside a git repository or when no tracked pubspec
  /// depends on a prismarine package by git.
  factory PinTree.find(String dir) {
    final top = Process.runSync('git', [
      '-C',
      dir,
      'rev-parse',
      '--show-toplevel',
    ]);
    if (top.exitCode != 0) {
      throw Failure('$dir is not in a git repository.');
    }
    final root = '${top.stdout}'.trim();
    final files = _tracked(root, '*pubspec.yaml');
    String? url;
    final pattern = RegExp(
      r'^  prismarine_\w+:\s*\n\s+git:\s*\n\s+url:\s*(\S+)',
      multiLine: true,
    );
    for (final f in files) {
      final m = pattern.firstMatch(File('$root/$f').readAsStringSync());
      if (m != null) {
        url = m[1];
        break;
      }
    }
    if (url == null) {
      throw Failure(
        'No pubspec in $root depends on a prismarine package by git.',
        fix: 'add the prismarine packages as git dependencies with a ref',
      );
    }
    final u = url;
    return PinTree._(
      root,
      u,
      [
        for (final f in files)
          if (File('$root/$f').readAsStringSync().contains('url: $u')) f,
      ],
      [
        for (final f in _tracked(root, '*Cargo.toml'))
          if (File('$root/$f').readAsStringSync().contains('git = "$u"')) f,
      ],
    );
  }

  /// The top folder of the repository.
  final String root;

  /// The git URL of the prismarine dependencies.
  final String url;

  /// The tracked pubspecs that depend on prismarine, relative to [root].
  final List<String> pubspecs;

  /// The tracked Cargo.toml files that depend on prismarine, relative to
  /// [root].
  final List<String> crates;

  /// The pinned commit. Throws a [Failure] when the files pin several.
  String get sha {
    final pins = <String>{
      for (final f in pubspecs)
        for (final m in RegExp(
          r'url: ' +
              RegExp.escape(url) +
              r'\n\s+path: [^\n]+\n\s+ref: ([0-9a-f]{40})',
        ).allMatches(File('$root/$f').readAsStringSync()))
          m[1]!,
      for (final f in crates)
        for (final m in RegExp(
          r'git = "' + RegExp.escape(url) + r'", rev = "([0-9a-f]{40})"',
        ).allMatches(File('$root/$f').readAsStringSync()))
          m[1]!,
    };
    if (pins.length != 1) {
      throw Failure(
        'The pubspecs and Cargo.toml files pin ${pins.length} commits: '
        '${pins.join(', ')}.',
        fix: 'prismarine pin <commit>',
      );
    }
    return pins.single;
  }

  /// Sets the pinned commit to [commit] in every pubspec and Cargo.toml.
  /// Returns the changed files.
  List<String> setPin(String commit) {
    final changed = <String>[];
    void rewrite(String f, RegExp pattern) {
      final file = File('$root/$f');
      final text = file.readAsStringSync();
      final next = text.replaceAllMapped(pattern, (m) => '${m[1]}$commit');
      if (next != text) {
        file.writeAsStringSync(next);
        changed.add(f);
      }
    }

    for (final f in pubspecs) {
      rewrite(
        f,
        RegExp(
          r'(url: ' +
              RegExp.escape(url) +
              r'\n\s+path: [^\n]+\n\s+ref: )[0-9a-f]{40}',
        ),
      );
    }
    for (final f in crates) {
      rewrite(
        f,
        RegExp(r'(git = "' + RegExp.escape(url) + r'", rev = ")[0-9a-f]{40}'),
      );
    }
    return changed;
  }

  /// The folders that resolve their packages on their own: the root and each
  /// folder of a pinned pubspec that is not a member of a workspace.
  List<String> get roots => {
    if (File('$root/pubspec.yaml').existsSync()) '.',
    for (final f in pubspecs)
      if (!File('$root/$f').readAsStringSync().contains(
        RegExp(r'^resolution: workspace$', multiLine: true),
      ))
        f.contains('/') ? f.substring(0, f.lastIndexOf('/')) : '.',
  }.toList();

  /// The overrides that `link` writes, by file relative to [root], for the
  /// prismarine checkout [checkout].
  Map<String, String> links(String checkout) {
    final packages = [
      for (final d in Directory('$checkout/packages').listSync())
        if (d is Directory && File('${d.path}/pubspec.yaml').existsSync())
          d.path,
    ]..sort();
    final out = <String, String>{};
    for (final d in roots) {
      final own = File('$root/$d/pubspec.yaml').readAsStringSync();
      final flutterRoot = own.contains('sdk: flutter');
      final b = StringBuffer()
        ..writeln(
          '# Written by prismarine pin link. Remove with prismarine pin unlink.',
        )
        ..writeln('dependency_overrides:');
      for (final p in packages) {
        // An override of a Flutter package would make a pure-Dart root a
        // Flutter one.
        if (!flutterRoot &&
            File(
              '$p/pubspec.yaml',
            ).readAsStringSync().contains('sdk: flutter')) {
          continue;
        }
        b.writeln('  ${p.split('/').last}:\n    path: $p');
      }
      for (final t in ['lint', 'profiler']) {
        if (Directory('$checkout/tools/$t').existsSync()) {
          b.writeln('  prismarine_$t:\n    path: $checkout/tools/$t');
        }
      }
      // The file replaces the pubspec's own overrides, which are copied. A
      // flutter_gpu override takes the checkout's flutter_gpu.
      final overrides = RegExp(
        r'^dependency_overrides:\n((?:(?:  .*|\s*)\n)*)',
        multiLine: true,
      ).firstMatch(own)?[1];
      if (overrides != null) {
        final entries = RegExp(
          r'^  (\w+):\n((?:    .*\n)*)',
          multiLine: true,
        ).allMatches(overrides);
        for (final e in entries) {
          if (e[1] == 'flutter_gpu') {
            b.writeln(
              '  flutter_gpu:\n    path: $checkout/third_party/flutter_gpu',
            );
          } else {
            b.write('  ${e[1]}:\n${e[2]}');
          }
        }
      }
      out['$d/pubspec_overrides.yaml'] = '$b';
    }
    for (final c in crates) {
      final dir = c.contains('/') ? c.substring(0, c.lastIndexOf('/')) : '.';
      final names = [
        for (final m in RegExp(
          '^(\\w+)\\s*=\\s*\\{[^}]*git = "${RegExp.escape(url)}"',
          multiLine: true,
        ).allMatches(File('$root/$c').readAsStringSync()))
          m[1]!,
      ];
      out['$dir/.cargo/config.toml'] = [
        '# Written by prismarine pin link. Remove with prismarine pin unlink.',
        '[patch."$url"]',
        for (final n in names) '$n = { path = "$checkout/packages/$n/native" }',
        '',
      ].join('\n');
    }
    return out;
  }

  /// The files that `link` wrote and that are still in place.
  List<String> get linked =>
      [
        for (final d in roots) '$d/pubspec_overrides.yaml',
        for (final c in crates)
          '${c.contains('/') ? c.substring(0, c.lastIndexOf('/')) : '.'}/.cargo/config.toml',
      ].where((f) {
        final file = File('$root/$f');
        return file.existsSync() &&
            file.readAsStringSync().contains('Written by prismarine pin link');
      }).toList();

  /// The source that the URL maps to on this computer, or null.
  String? get source {
    final r = Process.runSync('git', [
      'config',
      '--get-regexp',
      r'^url\..*\.insteadof$',
    ]);
    for (final line in '${r.stdout}'.split('\n')) {
      final parts = line.split(' ');
      if (parts.length == 2 && parts[1] == url) {
        return parts[0]
            .replaceFirst('url.', '')
            .replaceFirst(RegExp(r'\.insteadof$'), '');
      }
    }
    return null;
  }

  static List<String> _tracked(String root, String pattern) {
    final r = Process.runSync('git', ['-C', root, 'ls-files', pattern]);
    return [
      for (final l in '${r.stdout}'.split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
  }
}
