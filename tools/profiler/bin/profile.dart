// The player's VM-service profiler: attaches to a profile build and, per
// window of game time (read from the run's --profile frames.jsonl), records
// CPU samples (top self and inclusive functions), GC pauses (the timeline's
// GC stream) and the heap by class (the allocation profile: on this VM its
// "accumulated" figures are the
// heap's current contents and the reset does not clear them, so `alloc` and
// its mbPerSecond are what the heap holds, not an allocation rate; see
// heap_report.dart).
//
// dart run tools/profiler/bin/profile.dart <wsUri> <frames.jsonl> <outDir>
//     <name>:<t0>:<t1>...
//
// PROFILE_PERIOD=<µs> sets the sampling period (default 1000).
import 'dart:convert';
import 'dart:io';

import 'package:prismarine_profiler/summary.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// The game time of the last frame written to [path].
double? lastT(String path) {
  try {
    final raf = File(path).openSync();
    final len = raf.lengthSync();
    final start = len > 20000 ? len - 20000 : 0;
    raf.setPositionSync(start);
    final s = utf8.decode(raf.readSync(len - start), allowMalformed: true);
    raf.closeSync();
    for (final l in s.split('\n').reversed) {
      if (!l.startsWith('{') || !l.endsWith('}')) continue;
      final m = jsonDecode(l) as Map;
      if (m['t'] is num) return (m['t'] as num).toDouble();
    }
  } on Object {
    // Not written yet.
  }
  return null;
}

Future<void> main(List<String> args) async {
  final vm = await vmServiceConnectUri(args[0]);
  // PROFILE_TRACE=ClassA,ClassB: per-allocation stacks for those classes on
  // every isolate (counts per class and the code that allocated them; the
  // allocation profile is the isolate group's, so it can't tell them apart).
  final traced = (_env('TRACE') ?? '')
      .split(',')
      .where((c) => c.isNotEmpty)
      .toSet();
  final frames = args[1];
  final out = Directory(args[2])..createSync(recursive: true);
  await vm.setFlag('profiler', 'true');
  await vm.setFlag('profile_period', _env('PERIOD') ?? '1000');
  await vm.setVMTimelineFlags(['GC']);
  for (final w in [for (final a in args.skip(3)) a.split(':')]) {
    final name = w[0];
    final t0 = double.parse(w[1]), t1 = double.parse(w[2]);
    while ((lastT(frames) ?? -1) < t0) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final isolates = (await vm.getVM()).isolates ?? const <IsolateRef>[];
    for (final iso in isolates) {
      try {
        await vm.getAllocationProfile(iso.id!, reset: true);
      } on Object {
        // A worker isolate that has exited.
      }
    }
    final main = isolates.firstWhere(
      (i) => i.name == 'main',
      orElse: () => isolates.first,
    );
    final classIds = <String, String>{};
    if (traced.isNotEmpty) {
      final classes = await vm.getClassList(main.id!);
      for (final c in classes.classes ?? const <ClassRef>[]) {
        if (traced.contains(c.name)) classIds[c.name!] = c.id!;
      }
      for (final iso in isolates) {
        for (final id in classIds.values) {
          try {
            await vm.setTraceClassAllocation(iso.id!, id, true);
          } on Object {
            // A worker isolate that has exited.
          }
        }
      }
    }
    await vm.clearVMTimeline();
    final origin = (await vm.getVMTimelineMicros()).timestamp!;
    stderr.writeln('$name: from t=${lastT(frames)}');
    while ((lastT(frames) ?? -1) < t1) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final end = (await vm.getVMTimelineMicros()).timestamp!;
    final seconds = (end - origin) / 1e6;
    stderr.writeln('$name: to t=${lastT(frames)} ($seconds s)');
    final result = <String, Object?>{'window': w, 'seconds': seconds};
    for (final iso in (await vm.getVM()).isolates ?? const <IsolateRef>[]) {
      try {
        result[iso.name!] = await _isolate(vm, iso, origin, end - origin);
      } on Object catch (e) {
        result[iso.name!] = {'error': '$e'};
      }
    }
    if (classIds.isNotEmpty) {
      final traces = <String, Object?>{};
      for (final iso in (await vm.getVM()).isolates ?? const <IsolateRef>[]) {
        try {
          traces[iso.name!] = await _traces(vm, iso, classIds);
          for (final id in classIds.values) {
            await vm.setTraceClassAllocation(iso.id!, id, false);
          }
        } on Object catch (e) {
          traces[iso.name!] = {'error': '$e'};
        }
      }
      result['traces'] = traces;
    }
    // The target may have ended while the traces were read (a bounded
    // run): what was collected is still written.
    Timeline? tl;
    try {
      tl = await vm.getVMTimeline(
        timeOriginMicros: origin,
        timeExtentMicros: end - origin,
      );
    } on Object catch (e) {
      stderr.writeln('$name: no timeline ($e)');
    }
    final events = [
      for (final e in tl?.traceEvents ?? <TimelineEvent>[])
        if (e.json case final Map<String, Object?> j) j,
    ];
    result['gc'] = gcSummary(events, seconds);
    // A few collections' own numbers (heap sizes, reasons) for diagnosis.
    result['gcSample'] = [
      for (final e in events)
        if ((e['name'] as String? ?? '').startsWith('Collect') &&
            (e['args'] as Map?)?.isNotEmpty == true)
          {'name': e['name'], 'args': e['args']},
    ].take(6).toList();
    File(
      '${out.path}/$name.json',
    ).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(result));
  }
  // An observed VM pauses its isolates at exit by default: resume any that
  // are paused so the target can end (run targets with
  // --no-pause-isolates-on-exit too; tools/profiler/observe.sh does).
  try {
    for (final iso in (await vm.getVM()).isolates ?? const <IsolateRef>[]) {
      final kind = (await vm.getIsolate(iso.id!)).pauseEvent?.kind;
      if (kind == EventKind.kPauseExit || kind == EventKind.kPauseStart) {
        await vm.resume(iso.id!);
      }
    }
  } on Object {
    // The target is gone already.
  }
  await vm.dispose();
  exit(0);
}

Future<Map<String, Object?>> _isolate(
  VmService vm,
  IsolateRef iso,
  int origin,
  int extent,
) async {
  final cpu = await vm.getCpuSamples(iso.id!, origin, extent);
  final fns = cpu.functions ?? const <ProfileFunction>[];
  final samples = cpu.samples ?? const <CpuSample>[];
  // PROFILE_RAW=<dir>: every sample's stack (leaf first) as function names,
  // for call-tree breakdowns the top lists can't give.
  final raw = _env('RAW');
  if (raw != null && raw.isNotEmpty && samples.isNotEmpty) {
    String nameOf(int i) => switch (fns[i].function) {
      FuncRef(:final name, :final owner) => switch (owner) {
        ClassRef(name: final o?) => '$o.$name',
        FuncRef(name: final o?) => '$o.$name',
        _ => name ?? '?',
      },
      NativeFunction(:final name) => 'native $name',
      final f => '$f',
    };
    File('$raw/${iso.name}.${origin}.samples.json').writeAsStringSync(
      jsonEncode({
        'functions': [for (var i = 0; i < fns.length; i++) nameOf(i)],
        'stacks': [for (final s in samples) s.stack ?? const <int>[]],
        // Each sample's time (µs, the VM's clock): long stretches of one
        // stack show a synchronous chunk.
        'times': [for (final s in samples) s.timestamp],
      }),
    );
  }
  final self = <int, int>{}, incl = <int, int>{};
  // Caller → callee edges (inclusive, once per sample): enough of the call
  // tree to tell which caller a hot helper's time belongs to.
  final edges = <(int, int), int>{};
  for (final s in samples) {
    final st = s.stack ?? const <int>[];
    if (st.isEmpty) continue;
    self[st.first] = (self[st.first] ?? 0) + 1;
    for (final i in st.toSet()) {
      incl[i] = (incl[i] ?? 0) + 1;
    }
    for (final e in {
      for (var i = 0; i + 1 < st.length; i++) (st[i + 1], st[i]),
    }) {
      edges[e] = (edges[e] ?? 0) + 1;
    }
  }
  Map<String, Object?> describe(int i, int n) {
    final f = fns[i].function;
    final name = switch (f) {
      FuncRef(:final name, :final owner) => switch (owner) {
        ClassRef(name: final o?) => '$o.$name',
        FuncRef(name: final o?) => '$o.$name',
        _ => name ?? '?',
      },
      NativeFunction(:final name) => 'native $name',
      _ => '$f',
    };
    return {
      'n': n,
      'pct': samples.isEmpty ? 0 : n * 100 / samples.length,
      'fn': name,
      'url': fns[i].resolvedUrl ?? '',
    };
  }

  List<Map<String, Object?>> top(Map<int, int> m, int k) => [
    for (final e
        in (m.entries.toList()..sort((a, b) => b.value - a.value)).take(k))
      describe(e.key, e.value),
  ];
  final alloc = await vm.getAllocationProfile(iso.id!);
  return {
    'samples': samples.length,
    'self': top(self, 40),
    'inclusive': top(incl, 300),
    'edges': [
      for (final e
          in (edges.entries.toList()..sort((a, b) => b.value - a.value)).take(
            400,
          ))
        {
          'caller': describe(e.key.$1, e.value)['fn'],
          ...describe(e.key.$2, e.value),
        },
    ],
    'alloc': allocTop(
      [
        for (final m in alloc.members ?? const <ClassHeapStats>[])
          if ((m.accumulatedSize ?? 0) > 0)
            (m.classRef?.name ?? '?', m.accumulatedSize!),
      ],
      extent / 1e6,
      instances: {
        for (final m in alloc.members ?? const <ClassHeapStats>[])
          m.classRef?.name ?? '?': m.instancesAccumulated ?? 0,
      },
    ),
  };
}

/// Per traced class: allocations in the window and the top call sites (the
/// first frame of our code: mcsm packages, the player, flutter_scene).
Future<Map<String, Object?>> _traces(
  VmService vm,
  IsolateRef iso,
  Map<String, String> classIds,
) async {
  final out = <String, Object?>{};
  final oursIn = _env('OURS')?.split(',');
  for (final MapEntry(key: name, value: id) in classIds.entries) {
    // Every sample since tracing was enabled for this window (the
    // profiler's clock is not the timeline's).
    final t = await vm.getAllocationTraces(iso.id!, classId: id);
    final fns = t.functions ?? const <ProfileFunction>[];
    final sites = <String, int>{};
    final samples = t.samples ?? const <CpuSample>[];
    for (final s in samples) {
      // The first three frames in our code (the repo's packages, the
      // vendored flutter_scene / flutter_gpu), innermost first.
      final ours = <String>[];
      for (final i in s.stack ?? const <int>[]) {
        final url = fns[i].resolvedUrl ?? '';
        // Not the pub cache (it lives under the repo's data/, whose path
        // has "mcsm" in it): vector_math's constructors aren't the site.
        if (_isOurs(url, oursIn) && !url.contains('/pub-cache/')) {
          final f = fns[i].function;
          final fn = f is FuncRef
              ? '${(f.owner is ClassRef) ? '${(f.owner as ClassRef).name}.' : ''}${f.name}'
              : '$f';
          ours.add('$fn (${url.split('/').last})');
          if (ours.length == 3) break;
        }
      }
      String? site = ours.isEmpty ? null : ours.join(' < ');
      site ??= '(core)';
      sites[site] = (sites[site] ?? 0) + 1;
    }
    final times = [for (final s in samples) s.timestamp ?? 0]..sort();
    out[name] = {
      'count': samples.length,
      // The samples' time span (the profiler's sample buffer is a ring: a
      // span shorter than the window means older allocations were dropped).
      if (times.isNotEmpty) 'spanSeconds': (times.last - times.first) / 1e6,
      'sites': [
        for (final e
            in (sites.entries.toList()..sort((a, b) => b.value - a.value)).take(
              25,
            ))
          {'site': e.key, 'n': e.value},
      ],
    };
  }
  return out;
}

String? _env(String name) =>
    Platform.environment['PRISMARINE_PROFILE_$name'] ??
    Platform.environment['PROFILE_$name'];

bool _isOurs(String url, List<String>? ours) => ours == null
    ? url.isNotEmpty &&
          !url.startsWith('dart:') &&
          !url.contains('/sdk/lib/') &&
          !url.contains('org-dartlang-sdk')
    : ours.any(url.contains);
