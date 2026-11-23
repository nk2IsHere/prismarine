// Reports allocation by call site, weighted by bytes. It needs a Dart VM with
// the patch dart/0001 of the engine fork in third_party/flutter_engine. With
// --profiler and --heap_sample_traces=<n> the VM records the object of every
// n-th allocated byte as an allocation trace of the profiler. The identity
// hash of the sample holds its weight in bytes.
//
// dart run tools/profiler/bin/alloc_sites.dart <wsUri> <seconds> [out.json]
//     [--frames=<n>] [--top=<n>] [--isolate=<name>]
//     [--clock=<file> --from=<t> --to=<t>] [--once]
//
// The tool reads the allocation samples of each isolate every second for
// <seconds> or until the target exits. With --once it reads them once after
// the window. It prints for each isolate the bytes by class, by allocating
// site with the class and by function, inclusive. The site is the first frame
// outside the Dart SDK. --frames=<n> divides the bytes by n to give the bytes
// of a frame. --clock gives a file with one line per frame that ends in the
// game time, such as {"t": 12.5} in the frames.jsonl of FrameProfiler in
// prismarine_debug. Sampling then runs from the game time --from to --to and
// the bytes are per frame of the lines in that window.
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class _Isolate {
  final byClass = <String, int>{};
  final bySite = <String, int>{};
  final byFunction = <String, int>{};
  final byStack = <String, int>{};
  int total = 0, samples = 0;
}

Future<void> main(List<String> args) async {
  final flags = {
    for (final a in args.where((a) => a.startsWith('--')))
      a.substring(2).split('=').first: a.contains('=') ? a.split('=')[1] : '',
  };
  final pos = args.where((a) => !a.startsWith('--')).toList();
  final vm = await vmServiceConnectUri(pos[0]);
  final seconds = double.parse(pos[1]);
  final top = int.parse(flags['top'] ?? '40');
  final only = flags['isolate'];
  final stats = <String, _Isolate>{};
  final classNames = <String, Map<int, String>>{};
  final clock = flags['clock'];
  final from = double.tryParse(flags['from'] ?? '');
  final to = double.tryParse(flags['to'] ?? '');
  final once = flags.containsKey('once');
  var last = 0;
  // The allocation traces are samples of the profiler, which must run.
  await vm.setFlag('profiler', 'true');
  if (clock != null && from != null) {
    while ((_lastT(clock) ?? -1) < from) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  var origin = (await vm.getVMTimelineMicros()).timestamp!;
  final start = origin;
  final end = origin + (seconds * 1e6).round();
  var alive = true;
  while (alive &&
      origin < end &&
      !(clock != null && to != null && (_lastT(clock) ?? -1) >= to)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    int now;
    try {
      now = (await vm.getVMTimelineMicros()).timestamp!;
    } on Object {
      break;
    }
    if (now > end) now = end;
    // With --once the whole window is read once after it ends. A sample that
    // reaches the buffer after a read of its time then still counts.
    if (once) {
      last = now;
      continue;
    }
    try {
      for (final iso in (await vm.getVM()).isolates ?? const <IsolateRef>[]) {
        if (only != null && iso.name != only) continue;
        try {
          final s = await vm.getAllocationTraces(
            iso.id!,
            timeOriginMicros: origin,
            timeExtentMicros: now - origin,
          );
          final names = classNames.putIfAbsent(iso.id!, () => {});
          await _add(
            vm,
            iso,
            s,
            stats.putIfAbsent(iso.name!, _Isolate.new),
            names,
          );
        } on RPCError {
          // An isolate that exited between the listing and the read.
        }
      }
    } on Object {
      alive = false;
    }
    origin = now;
  }
  if (once) {
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final iso in (await vm.getVM()).isolates ?? const <IsolateRef>[]) {
      if (only != null && iso.name != only) continue;
      try {
        final s = await vm.getAllocationTraces(
          iso.id!,
          timeOriginMicros: start,
          timeExtentMicros: last - start,
        );
        await _add(
          vm,
          iso,
          s,
          stats.putIfAbsent(iso.name!, _Isolate.new),
          classNames.putIfAbsent(iso.id!, () => {}),
        );
      } on RPCError {
        // An isolate that exited since.
      }
    }
    origin = last;
  }
  final wall = (origin - start) / 1e6;
  var perFrame = double.parse(flags['frames'] ?? '1');
  if (clock != null && from != null) {
    final n = _framesIn(clock, from, to ?? double.infinity);
    if (n > 0) perFrame = n.toDouble();
    stdout.writeln('$n frames in $from..$to over ${wall.toStringAsFixed(1)} s');
  }
  final report = <String, Object?>{'seconds': wall, 'perFrame': perFrame};
  for (final MapEntry(key: name, value: st) in stats.entries) {
    if (st.samples == 0) continue;
    String mb(int b) => (b / perFrame / 1e6).toStringAsFixed(3);
    stdout.writeln(
      '\n== $name: ${mb(st.total)} MB'
      '${perFrame == 1 ? '' : ' a frame'}, ${st.samples} samples, '
      '${(st.total / wall / 1e6).toStringAsFixed(1)} MB/s',
    );
    for (final (title, m) in [
      ('class', st.byClass),
      ('site (first frame outside the SDK) · class', st.bySite),
      ('function, inclusive', st.byFunction),
    ]) {
      stdout.writeln('-- by $title');
      final sorted = m.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted.take(top)) {
        final pct = (100 * e.value / st.total).toStringAsFixed(1);
        stdout.writeln(
          '${mb(e.value).padLeft(9)} ${pct.padLeft(5)}%  ${e.key}',
        );
      }
    }
    report[name] = {
      'bytes': st.total,
      'samples': st.samples,
      'byClass': st.byClass,
      'bySite': st.bySite,
      'byFunction': st.byFunction,
      'byStack': st.byStack,
    };
  }
  if (pos.length > 2) File(pos[2]).writeAsStringSync(jsonEncode(report));
  await vm.dispose();
}

Future<void> _add(
  VmService vm,
  IsolateRef iso,
  CpuSamples s,
  _Isolate st,
  Map<int, String> classNames,
) async {
  final fns = [for (final f in s.functions ?? const <ProfileFunction>[]) f];
  final labels = [for (final f in fns) _label(f)];
  final sdk = [for (final f in fns) _isSdk(f)];
  for (final sample in s.samples ?? const <CpuSample>[]) {
    final bytes = sample.identityHashCode ?? 0;
    final cid = sample.classId;
    if (bytes <= 0 || cid == null) continue;
    final cls = classNames[cid] ??= await _className(vm, iso, cid);
    final stack = sample.stack ?? const <int>[];
    st.total += bytes;
    st.samples++;
    st.byClass.update(cls, (v) => v + bytes, ifAbsent: () => bytes);
    // The site is the innermost frame outside the SDK. The growth or copy of
    // an SDK collection is charged to the code that called it.
    var site = stack.isEmpty ? '?' : labels[stack.first];
    for (final i in stack) {
      if (!sdk[i]) {
        site = labels[i];
        break;
      }
    }
    final key = '$site · $cls';
    st.bySite.update(key, (v) => v + bytes, ifAbsent: () => bytes);
    final seen = <int>{};
    for (final i in stack) {
      if (seen.add(i)) {
        st.byFunction.update(
          labels[i],
          (v) => v + bytes,
          ifAbsent: () => bytes,
        );
      }
    }
    final chain = [for (final i in stack) labels[i]].join(' < ');
    st.byStack.update('$cls @ $chain', (v) => v + bytes, ifAbsent: () => bytes);
  }
}

Future<String> _className(VmService vm, IsolateRef iso, int cid) async {
  try {
    final c = await vm.getObject(iso.id!, 'classes/$cid');
    if (c is Class) return c.name ?? 'cid $cid';
  } on Object {
    // A VM-internal class without a service object.
  }
  return 'cid $cid';
}

String _label(ProfileFunction f) {
  final fn = f.function;
  if (fn is FuncRef) {
    final owner = fn.owner;
    final name = switch (owner) {
      ClassRef(:final name) => '$name.${fn.name}',
      FuncRef(:final name) => '$name.${fn.name}',
      _ => fn.name ?? '?',
    };
    final uri = f.resolvedUrl ?? '';
    final file = uri.isEmpty ? '' : ' (${uri.split('/').last})';
    return '$name$file';
  }
  if (fn is NativeFunction) return '[native] ${fn.name}';
  return '${fn is ObjRef ? fn.id : fn}';
}

bool _isSdk(ProfileFunction f) {
  final uri = f.resolvedUrl ?? '';
  return uri.isEmpty ||
      uri.startsWith('dart:') ||
      uri.contains('/sdk/lib/') ||
      uri.contains('org-dartlang-sdk');
}

/// The game time of the last line in [path].
double? _lastT(String path) {
  try {
    final raf = File(path).openSync();
    final len = raf.lengthSync();
    final start = len > 20000 ? len - 20000 : 0;
    raf.setPositionSync(start);
    final text = utf8.decode(raf.readSync(len - start), allowMalformed: true);
    raf.closeSync();
    for (final l in text.split('\n').reversed) {
      if (_t(l) case final t?) return t;
    }
  } on Object {
    // The file does not exist yet.
  }
  return null;
}

/// Counts the lines of [path] with a game time in [from, to).
int _framesIn(String path, double from, double to) {
  var n = 0;
  for (final l in File(path).readAsLinesSync()) {
    final t = _t(l);
    if (t != null && t >= from && t < to) n++;
  }
  return n;
}

double? _t(String line) {
  if (!line.startsWith('{') || !line.endsWith('}')) return null;
  try {
    final m = jsonDecode(line);
    return m is Map && m['t'] is num ? (m['t'] as num).toDouble() : null;
  } on FormatException {
    return null;
  }
}
