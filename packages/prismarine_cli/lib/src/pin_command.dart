import 'dart:io';

import 'package:args/command_runner.dart';

import 'base_command.dart';
import 'pin.dart';
import 'ui.dart';

const _actions = {
  'show':
      'Prints the URL, the pinned commit, its source and the checkout in use. The default.',
  '<commit>':
      'Pins that commit in every pubspec and Cargo.toml, then resolves every folder that resolves on its own.',
  'check':
      'Fails unless the pin is in the main branch of its source and pub resolved the repository to it.',
  'link <checkout>':
      'Resolves prismarine from a local checkout through override files.',
  'unlink': 'Removes the override files of link.',
  'checkout':
      'Prints the prismarine checkout in use, the linked one or the pin in the pub cache.',
  'map <source>':
      'Maps the URL to a repository in the global git config of this computer.',
  'ship <host> <dir>':
      'Makes the bare repository <dir> on ssh <host> hold the pinned commit.',
};

/// `prismarine pin`: the pin of prismarine in a repository that depends on
/// it as a git dependency.
class PinCommand extends BaseCommand {
  @override
  String get name => 'pin';
  @override
  String get description =>
      'Pins prismarine in a repository that depends on it by git, and checks, links or ships the pin.';
  @override
  String get invocation => 'prismarine pin [<action>]';
  @override
  String get usageFooter =>
      '\n\nActions:\n${[for (final MapEntry(:key, :value) in _actions.entries) '  ${key.padRight(19)}$value'].join('\n')}';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    final t = PinTree.find(Directory.current.path);
    switch (rest) {
      case [] || ['show']:
        ui.line('url      ${t.url}');
        ui.line('pin      ${t.sha}');
        ui.line('source   ${t.source ?? 'none (prismarine pin map <source>)'}');
        ui.line('checkout ${_checkout(t) ?? 'not resolved (dart pub get)'}');
        if (t.linked.isNotEmpty) ui.line('linked   ${t.linked.join(', ')}');
      case ['check']:
        _check(t);
      case ['link', final checkout]:
        final dir = Directory(checkout).absolute.path;
        if (!File('$dir/third_party/flutter_engine/RELEASE').existsSync()) {
          throw _fail(
            '$dir is not a prismarine checkout.',
            'pass the folder of a prismarine checkout',
          );
        }
        for (final MapEntry(:key, :value) in t.links(dir).entries) {
          File('${t.root}/$key')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(value);
          ui.line('wrote $key');
        }
        ui.line('Run prismarine pin unlink and resolve again before a commit.');
      case ['unlink']:
        for (final f in t.linked) {
          final file = File('${t.root}/$f')..deleteSync();
          if (f.endsWith('.cargo/config.toml') &&
              file.parent.listSync().isEmpty) {
            file.parent.deleteSync();
          }
          ui.line('removed $f');
        }
      case ['checkout']:
        final c = _checkout(t);
        if (c == null) {
          throw _fail(
            'The pin ${t.sha} is not in the pub cache.',
            'dart pub get, in ${t.root}',
          );
        }
        stdout.writeln(c);
      case ['url']:
        stdout.writeln(t.url);
      case ['sha']:
        stdout.writeln(t.sha);
      case ['source']:
        final s = t.source;
        if (s != null) stdout.writeln(s);
      case ['map', final source]:
        Process.runSync('git', [
          'config',
          '--global',
          'url.$source.insteadOf',
          t.url,
        ]);
        ui.line('${t.url} maps to $source');
      case ['ship', final host, final dir]:
        _ship(t, host, dir);
      case [final commit] when RegExp(r'^[0-9a-f]{7,40}$').hasMatch(commit):
        await _pin(t, commit);
      default:
        throw UsageException('Unknown action "${rest.join(' ')}".', usage);
    }
    return 0;
  }

  Failure _fail(String cause, String fix) {
    final f = Failure(cause, fix: fix);
    ui.printFailure(f);
    return f;
  }

  /// The full commit of [commit] in the source, or [commit] itself when it
  /// has 40 digits and the source is not a local folder.
  String _resolve(PinTree t, String commit) {
    final s = t.source;
    if (s != null && Directory(s).existsSync()) {
      final r = Process.runSync('git', [
        '-C',
        s,
        'rev-parse',
        '--verify',
        '$commit^{commit}',
      ]);
      if (r.exitCode == 0) return '${r.stdout}'.trim();
      throw _fail(
        '$s has no commit $commit.',
        'fetch it, or give a commit of $s',
      );
    }
    if (commit.length == 40) return commit;
    throw _fail(
      'A short commit needs a local source to resolve it.',
      'give all 40 digits, or prismarine pin map <local checkout>',
    );
  }

  Future<void> _pin(PinTree t, String commit) async {
    needFlutter();
    final full = _resolve(t, commit);
    final changed = t.setPin(full);
    ui.line('pinned ${full.substring(0, 12)} in ${changed.length} files');
    for (final c in t.crates) {
      // Cargo resolves the moved dependency again and keeps the other versions.
      await steps(null).tools.must(
        ['cargo', 'fetch', '-q', '--manifest-path', '${t.root}/$c'],
        log: 'pin-cargo',
        cause: '`cargo fetch` failed for $c.',
      );
    }
    for (final d in t.roots) {
      final flutter = File(
        '${t.root}/$d/pubspec.yaml',
      ).readAsStringSync().contains('sdk: flutter');
      await ui.step('packages $d', () async {
        await steps(null).tools.must(
          [flutter ? toolchain.flutter : toolchain.dart, 'pub', 'get'],
          dir: '${t.root}/$d',
          log: 'pin-pub-get',
          cause: '`pub get` failed in $d.',
          fix: 'prismarine ${flutter ? 'flutter' : 'dart'} pub get, in $d',
        );
      }, done: (_) => 'resolved');
    }
  }

  String? _checkout(PinTree t) {
    final over = File('${t.root}/pubspec_overrides.yaml');
    if (over.existsSync() &&
        over.readAsStringSync().contains('Written by prismarine pin link')) {
      final m = RegExp(
        r'path: (.*)/packages/prismarine_\w+$',
        multiLine: true,
      ).firstMatch(over.readAsStringSync());
      if (m != null) return m[1];
    }
    final cache =
        toolchain.pubCache ??
        '${Platform.environment['HOME'] ?? Platform.environment['LOCALAPPDATA']}/.pub-cache';
    final name = t.url.split('/').last.replaceFirst(RegExp(r'\.git$'), '');
    final dir = '$cache/git/$name-${t.sha}';
    return File('$dir/third_party/flutter_engine/RELEASE').existsSync()
        ? dir
        : null;
  }

  void _check(PinTree t) {
    final pin = t.sha;
    final s =
        t.source ??
        (throw _fail(
          'No source for ${t.url} on this computer.',
          'prismarine pin map <source>',
        ));
    var git = s;
    Directory? tmp;
    if (!Directory(s).existsSync()) {
      // A remote source is read through a bare clone without blobs.
      tmp = Directory.systemTemp.createTempSync('prismarine-pin');
      final r = Process.runSync('git', [
        'clone',
        '-q',
        '--bare',
        '--filter=blob:none',
        s,
        tmp.path,
      ]);
      if (r.exitCode != 0) {
        throw _fail('git cannot clone $s.', 'check the access to $s');
      }
      git = tmp.path;
    }
    try {
      if (Process.runSync('git', [
            '-C',
            git,
            'cat-file',
            '-e',
            '$pin^{commit}',
          ]).exitCode !=
          0) {
        throw _fail(
          'The pin $pin is not a commit of $s.',
          'prismarine pin <a commit of $s>',
        );
      }
      if (Process.runSync('git', [
            '-C',
            git,
            'merge-base',
            '--is-ancestor',
            pin,
            'refs/heads/main',
          ]).exitCode !=
          0) {
        throw _fail(
          'The pin $pin is not in the main branch of $s.',
          'land it in prismarine first',
        );
      }
    } finally {
      tmp?.deleteSync(recursive: true);
    }
    if (t.linked.isNotEmpty) {
      throw _fail(
        '${t.linked.first} points to a local checkout.',
        'prismarine pin unlink, then resolve again',
      );
    }
    final cfg = File('${t.root}/.dart_tool/package_config.json');
    if (!cfg.existsSync()) {
      throw _fail('No ${cfg.path}.', 'dart pub get, in ${t.root}');
    }
    // Pub keeps a git dependency in a folder whose name ends in the commit.
    if (!cfg.readAsStringSync().contains(RegExp('-$pin/'))) {
      throw _fail(
        '${cfg.path} does not resolve prismarine to the pin $pin.',
        'dart pub get, in ${t.root}',
      );
    }
    ui.line('the pin $pin is in main of $s and resolved');
  }

  void _ship(PinTree t, String host, String dir) {
    final pin = t.sha;
    // Cargo fetches the branches and HEAD of the repository, pub any commit.
    // Each pin gets a branch, and HEAD points to the last one shipped.
    final head = "git -C '$dir' symbolic-ref HEAD refs/heads/pins/$pin";
    if (Process.runSync('ssh', [
          '-o',
          'BatchMode=yes',
          host,
          "git -C '$dir' rev-parse -q --verify 'refs/heads/pins/$pin' >/dev/null && $head",
        ]).exitCode ==
        0) {
      ui.line('$host:$dir already holds $pin');
      return;
    }
    final s = t.source;
    if (s == null || !Directory(s).existsSync()) {
      throw _fail(
        'ship needs a local source for ${t.url}.',
        'prismarine pin map <local checkout>',
      );
    }
    Process.runSync('ssh', [
      '-o',
      'BatchMode=yes',
      host,
      "[ -d '$dir' ] || git init -q --bare '$dir'",
    ]);
    final push = Process.runSync('git', [
      '-C',
      s,
      'push',
      '-q',
      '$host:$dir',
      '$pin:refs/pins/$pin',
      '$pin:refs/heads/pins/$pin',
    ]);
    if (push.exitCode != 0) {
      throw _fail(
        'git push to $host:$dir failed: ${push.stderr}',
        'check ssh $host',
      );
    }
    Process.runSync('ssh', ['-o', 'BatchMode=yes', host, head]);
    ui.line('$host:$dir holds $pin');
  }
}
