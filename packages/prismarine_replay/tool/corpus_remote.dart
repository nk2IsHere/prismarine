// Runs a command of a game's corpus program on another machine over ssh: ships
// the committed head of a tree with git archive, builds the corpus program
// there once, runs the command and copies the results back. --help lists the
// commands and the settings. It needs ssh, scp, rsync and git, so it runs on
// macOS and Linux.
import 'dart:io';

const _usage = '''
corpus_remote.dart <command> <tree> [args…]
  check       runs the check and copies its report back. --expect=<file>
              takes a local file. The exit code is the check's.
  baseline, rebaseline, record, snapshots
              runs the command and copies the runs and the baseline back
The settings are environment variables:
  CORPUS_HOST     the ssh host
  CORPUS_ROOT     the remote folder that holds trees/ and the remote corpus
  CORPUS_DIR      the remote corpus folder, \$CORPUS_ROOT/data/corpus by
                  default. The corpus program must use it by default.
  CORPUS_WRAP     a command in \$CORPUS_ROOT that runs its argument, a shell
                  command line, in the build container. bash -c by default.
  CORPUS_PACKAGE  the package of the tree that holds tool/corpus.dart
  CORPUS_LOCAL    the local corpus folder that receives the results
  CORPUS_JOBS     the replays at the same time, 16 by default
  CORPUS_SHIP     an optional command line that runs in <tree> before the
                  tree is shipped, such as one that ships its pinned
                  dependencies''';

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.first.startsWith('-')) {
    stdout.writeln(_usage);
    exit(args.isEmpty || args.first == '--help' || args.first == '-h' ? 0 : 2);
  }
  final env = Platform.environment;
  String need(String k) =>
      env[k] ?? (throw StateError('corpus_remote: set $k'));
  final host = need('CORPUS_HOST');
  final root = need('CORPUS_ROOT');
  final package = need('CORPUS_PACKAGE');
  final local = need('CORPUS_LOCAL');
  final dir = env['CORPUS_DIR'] ?? '$root/data/corpus';
  final wrap = env['CORPUS_WRAP'] ?? 'bash -c';
  final jobs = env['CORPUS_JOBS'] ?? '16';
  final [command, tree, ...rest] = args;

  final name = await _ship(tree, host, root, wrap, package, env['CORPUS_SHIP']);
  Future<int> runRemote(List<String> commandArgs) => _ssh(host, [
    "cd $root && $wrap 'cd trees/$name/$package && "
        "CORPUS_COMMIT=${name.split('-').last} dart run tool/corpus.dart "
        "${commandArgs.join(' ')} --jobs=$jobs "
        "--exe=$root/trees/$name/bin/bundle/bin/corpus'",
  ]);

  switch (command) {
    case 'check':
      final remoteArgs = <String>[];
      for (final a in rest) {
        if (a.startsWith('--expect=')) {
          final remote = '$dir/expect-$name.txt';
          await _run('scp', ['-q', a.substring(9), '$host:$remote']);
          remoteArgs.add('--expect=$remote');
        } else {
          remoteArgs.add(a);
        }
      }
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[-:]'), '')
          .replaceFirst('T', '-')
          .substring(0, 15);
      final out = 'checks/$name-$stamp';
      final code = await runRemote(['check', ...remoteArgs, '--out=$dir/$out']);
      Directory('$local/$out').createSync(recursive: true);
      await _run('rsync', [
        '-a',
        '--exclude=*.fp.gz',
        '$host:$dir/$out/',
        '$local/$out/',
      ]);
      stdout.writeln(
        'report: $local/$out/report.txt (fingerprints stay on the remote '
        'machine: $dir/$out)',
      );
      exit(code);
    case 'baseline' || 'rebaseline' || 'record' || 'snapshots':
      final code = await runRemote([command, ...rest]);
      if (code != 0) exit(code);
      exit(
        await _run('rsync', [
          '-a',
          '$host:$dir/runs',
          '$host:$dir/baseline',
          '$local/',
        ]),
      );
    default:
      stderr.writeln('corpus_remote: unknown command $command');
      exit(2);
  }
}

/// Ships the committed head of [tree] to `<root>/trees/<name>` and builds the
/// corpus program there, unless it is built already. Returns `<name>`, the
/// tree's folder and its commit.
Future<String> _ship(
  String tree,
  String host,
  String root,
  String wrap,
  String package,
  String? shipCommand,
) async {
  final head = Process.runSync('git', [
    '-C',
    tree,
    'rev-parse',
    '--short=8',
    'HEAD',
  ]);
  if (head.exitCode != 0) {
    throw StateError('corpus_remote: $tree is not a git tree');
  }
  final name =
      '${Directory(tree).absolute.uri.pathSegments.where((s) => s.isNotEmpty).last}-'
      '${'${head.stdout}'.trim()}';
  if (shipCommand != null && shipCommand.isNotEmpty) {
    final r = await _run(
      'bash',
      ['-c', shipCommand],
      dir: tree,
      toStderr: true,
    );
    if (r != 0) throw StateError('corpus_remote: CORPUS_SHIP failed with $r');
  }
  if (await _ssh(host, [
        'test -x $root/trees/$name/bin/bundle/bin/corpus',
      ], quiet: true) ==
      0) {
    return name;
  }
  // git archive | ssh tar: the pipe runs in Dart.
  final archive = await Process.start('git', [
    '-C', tree, 'archive', '--format=tar', '--prefix=$name/', 'HEAD', //
  ]);
  final untar = await Process.start('ssh', [
    '-o', 'BatchMode=yes', host, //
    'mkdir -p $root/trees && cd $root/trees && rm -rf $name && tar -xf - 2>/dev/null',
  ]);
  await archive.stdout.pipe(untar.stdin);
  await untar.exitCode;
  final built = await _ssh(host, [
    "cd $root && $wrap 'cd trees/$name && dart pub get >/dev/null && "
        'cd $package && dart build cli -t tool/corpus.dart '
        "-o $root/trees/$name/bin >/dev/null'",
  ], toStderr: true);
  if (built != 0) throw StateError('corpus_remote: the build on $host failed');
  return name;
}

Future<int> _ssh(
  String host,
  List<String> command, {
  bool quiet = false,
  bool toStderr = false,
}) => _run(
  'ssh',
  ['-o', 'BatchMode=yes', host, ...command],
  quiet: quiet,
  toStderr: toStderr,
);

/// Runs [exe] with [args] and returns its exit code. Its output goes to
/// stdout, or to stderr with [toStderr], or nowhere with [quiet].
Future<int> _run(
  String exe,
  List<String> args, {
  String? dir,
  bool quiet = false,
  bool toStderr = false,
}) async {
  final p = await Process.start(exe, args, workingDirectory: dir);
  await Future.wait([
    p.stdout.forEach((b) {
      if (!quiet) (toStderr ? stderr : stdout).add(b);
    }),
    p.stderr.forEach((b) {
      if (!quiet) stderr.add(b);
    }),
  ]);
  return p.exitCode;
}
