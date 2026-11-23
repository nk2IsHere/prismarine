// What a running player holds in its Dart heap (usage: --help).
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _usage = r'''
What a running player holds in its Dart heap: attaches to a profile
build's VM service and reads, at given game times (from the run's
--profile frames.jsonl):

  heap: a heap snapshot of one isolate (the group's heap), its objects of
        the chosen classes grouped by the path that retains them (the
        first path a breadth-first walk from the roots finds), largest
        total first.
  live: each chosen class's bytes and instances in the heap now.

The VM's allocation profile is not an allocation rate: on this VM (Dart
3.13) `accumulatedSize` equals `bytesCurrent` and `reset: true` does not
clear it, so "MB per window" from it is the heap's contents. `live` shows
it (both columns over time); allocation rates come from GC stats
(`--verbose_gc` headless, the timeline's GC events) or allocation traces.

  dart run tools/profiler/bin/heap_report.dart heap <ws> <frames.jsonl> <t>
      [--classes=_Uint8List,_ByteDataView] [--min=<bytes>] [--max=<bytes>]
      [--depth=<n>] [--isolate=main] [--top=<n>]
  dart run tools/profiler/bin/heap_report.dart live <ws> <frames.jsonl>
      <class,class…> <t>…
''';

/// The game time of the last frame written to [path] (null before one).
double? lastT(String path) {
  try {
    final s = File(path).readAsStringSync();
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

Future<void> _until(String frames, double t) async {
  while ((lastT(frames) ?? -1) < t) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

String? _opt(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    exit(0);
  }
  if (args.length < 4 || !const {'heap', 'live'}.contains(args[0])) {
    stderr.write(_usage);
    exit(64);
  }
  final vm = await vmServiceConnectUri(args[1]);
  try {
    if (args[0] == 'heap') {
      await _heap(vm, args);
    } else {
      await _live(vm, args);
    }
  } finally {
    await vm.dispose();
  }
}

Future<IsolateRef> _isolate(VmService vm, String name) async {
  final isolates = (await vm.getVM()).isolates ?? const <IsolateRef>[];
  return isolates.firstWhere(
    (i) => i.name == name,
    orElse: () => isolates.first,
  );
}

Future<void> _live(VmService vm, List<String> args) async {
  final frames = args[2];
  final classes = args[3].split(',').toSet();
  final iso = await _isolate(vm, 'main');
  for (final a in args.skip(4)) {
    await _until(frames, double.parse(a));
    final p = await vm.getAllocationProfile(iso.id!);
    final row = [
      for (final m in p.members ?? const <ClassHeapStats>[])
        if (classes.contains(m.classRef?.name))
          '${m.classRef?.name} ${m.bytesCurrent} B in ${m.instancesCurrent} '
              '(accumulated ${m.accumulatedSize} B in '
              '${m.instancesAccumulated})',
    ];
    print('t=${lastT(frames)?.toStringAsFixed(2)}: ${row.join(' | ')}');
  }
}

Future<void> _heap(VmService vm, List<String> args) async {
  final frames = args[2];
  final t = double.parse(args[3]);
  final classes =
      (_opt(args, 'classes') ??
              '_Uint8List,_ByteDataView,_Float32List,_Float64List,'
                  '_Int32List,_Uint32List,_Uint16List')
          .split(',')
          .toSet();
  final lo = int.tryParse(_opt(args, 'min') ?? '') ?? 0;
  final hi = int.tryParse(_opt(args, 'max') ?? '') ?? 1 << 40;
  final depth = int.tryParse(_opt(args, 'depth') ?? '') ?? 6;
  final top = int.tryParse(_opt(args, 'top') ?? '') ?? 25;
  await _until(frames, t);
  final iso = await _isolate(vm, _opt(args, 'isolate') ?? 'main');
  final g = await HeapSnapshotGraph.getSnapshot(vm, iso);
  final objs = g.objects;
  final cls = g.classes;
  // The first referrer of each object on a breadth-first walk from the
  // root (object 1), and which of its references it is.
  final parent = List<int>.filled(objs.length, -1);
  final parentSlot = List<int>.filled(objs.length, -1);
  final queue = <int>[1];
  parent[1] = 1;
  for (var qi = 0; qi < queue.length; qi++) {
    final o = queue[qi];
    final refs = objs[o].references;
    for (var j = 0; j < refs.length; j++) {
      final r = refs[j];
      if (r <= 0 || r >= objs.length || parent[r] != -1) continue;
      parent[r] = o;
      parentSlot[r] = j;
      queue.add(r);
    }
  }
  String name(int i) {
    final c = cls[objs[i].classId];
    final lib = c.libraryUri.toString().split('/').last;
    return lib.isEmpty ? c.name : '${c.name} ($lib)';
  }

  final bytes = <String, int>{};
  final counts = <String, int>{};
  final range = <String, (int, int)>{};
  var total = 0, n = 0;
  for (var i = 1; i < objs.length; i++) {
    final o = objs[i];
    if (!classes.contains(cls[o.classId].name)) continue;
    final size = o.shallowSize;
    if (size < lo || size > hi) continue;
    final path = <String>[name(i)];
    var p = i;
    for (var d = 0; d < depth; d++) {
      final pp = parent[p];
      if (pp == -1 || pp == p) break;
      final slot = parentSlot[p];
      // The field holding it by its reference index; list elements and
      // the rest as [].
      var field = '[]';
      for (final f in cls[objs[pp].classId].fields) {
        if (f.index == slot) field = '.${f.name}';
      }
      path.add('${name(pp)} $field');
      p = pp;
    }
    final key = path.join('\n    ← ');
    bytes[key] = (bytes[key] ?? 0) + size;
    counts[key] = (counts[key] ?? 0) + 1;
    final (a, b) = range[key] ?? (size, size);
    range[key] = (size < a ? size : a, size > b ? size : b);
    total += size;
    n++;
  }
  print(
    '${iso.name} at t=${lastT(frames)?.toStringAsFixed(2)}: '
    '${objs.length} objects; ${classes.join(', ')}: '
    '${(total / 1e6).toStringAsFixed(1)} MB in $n',
  );
  for (final k
      in (bytes.keys.toList()..sort((a, b) => bytes[b]! - bytes[a]!)).take(
        top,
      )) {
    final (a, b) = range[k]!;
    print(
      '\n${(bytes[k]! / 1e6).toStringAsFixed(2)} MB in ${counts[k]} '
      '($a..$b B)\n  $k',
    );
  }
}
