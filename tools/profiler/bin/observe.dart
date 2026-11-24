// Runs a headless Dart program under the VM service and profiles it with
// profile.dart over windows of game time.
//
//   dart tools/profiler/bin/observe.dart <out dir> "<name:t0:t1> …" <script> [script args…]
//
// The program writes one line per frame with its game time, such as
// {"t": 12.5}, to the file in PRISMARINE_OBSERVE_CLOCK, <out dir>/frames.jsonl
// by default. It runs with --no-pause-isolates-on-exit as the leader of a
// process group of its own, which is stopped at the end, on INT and after
// PRISMARINE_OBSERVE_TIMEOUT seconds, 1800 by default.
// PRISMARINE_OBSERVE_DART_FLAGS adds flags of the VM, such as
// --no-inline-alloc for PRISMARINE_PROFILE_TRACE.
// PRISMARINE_PROFILER_PACKAGES gives the package config of profile.dart in a
// checkout without one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: observe.dart <out dir> "<name:t0:t1> …" <script> [script args…]',
    );
    exit(2);
  }
  final [outArg, windows, script, ...scriptArgs] = args;
  final env = Platform.environment;
  final out = Directory(outArg)..createSync(recursive: true);
  final clock =
      env['PRISMARINE_OBSERVE_CLOCK'] ?? '${out.absolute.path}/frames.jsonl';
  // The frames of an earlier run would end the windows at once.
  if (File(clock).existsSync()) File(clock).deleteSync();
  final flags = (env['PRISMARINE_OBSERVE_DART_FLAGS'] ?? '').split(' ')
    ..removeWhere((f) => f.isEmpty);
  final timeout = int.tryParse(env['PRISMARINE_OBSERVE_TIMEOUT'] ?? '') ?? 1800;
  final program = await Process.start(
    Platform.resolvedExecutable,
    [
      ...flags,
      'run',
      '--observe=0',
      '--no-pause-isolates-on-exit',
      '--disable-service-auth-codes',
      script,
      ...scriptArgs,
    ],
    environment: {'PRISMARINE_OBSERVE_CLOCK': clock, 'BENCH_FRAMES': clock},
    mode: ProcessStartMode.detachedWithStdio,
  );
  void stop() {
    if (Platform.isWindows) {
      Process.runSync('taskkill', ['/T', '/F', '/PID', '${program.pid}']);
    } else {
      Process.runSync('kill', ['-TERM', '-${program.pid}']);
    }
  }

  ProcessSignal.sigint.watch().listen((_) {
    stop();
    exit(130);
  });
  final timer = Timer(Duration(seconds: timeout), () {
    stderr.writeln('observe: timeout after $timeout s');
    stop();
    exit(124);
  });
  final log = File('${out.path}/stdout.txt').openWrite();
  final text = StringBuffer();
  void take(List<int> bytes) {
    log.add(bytes);
    text.write(utf8.decode(bytes, allowMalformed: true));
  }

  final streams = [
    program.stdout.listen(take).asFuture<void>(),
    program.stderr.listen(take).asFuture<void>(),
  ];
  final pattern = RegExp(r'http://127\.0\.0\.1:\d+/');
  String? uri;
  for (var i = 0; i < 180 && uri == null && _alive(program.pid); i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    uri = pattern.firstMatch(text.toString())?[0];
  }
  if (uri == null) {
    stdout.writeln('observe: no VM service URI');
    stop();
    exit(1);
  }
  final packages = env['PRISMARINE_PROFILER_PACKAGES'];
  final profile = await Process.start(Platform.resolvedExecutable, [
    if (packages != null && packages.isNotEmpty) '--packages=$packages',
    '${File(Platform.script.toFilePath()).parent.path}/profile.dart',
    'ws://${uri.substring('http://'.length)}ws',
    clock,
    out.path,
    ...windows.split(RegExp(r'\s+')).where((w) => w.isNotEmpty),
  ], mode: ProcessStartMode.inheritStdio);
  final code = await profile.exitCode;
  // A detached process has no exit code, so its end is polled.
  for (var i = 0; i < 30 && _alive(program.pid); i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  timer.cancel();
  stop();
  await Future.wait(
    streams,
  ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
  await log.close();
  exit(code);
}

/// True while the process [pid] runs.
bool _alive(int pid) => Platform.isWindows
    ? '${Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']).stdout}'
          .contains('$pid')
    : Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
