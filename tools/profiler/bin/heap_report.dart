// Reports the Dart heap of a running app. --help prints the usage.
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const _usage = r'''
Reports the Dart heap of a running app. The tool attaches to the VM service
of a profile build and waits for each game time in the clock file, the
frames.jsonl of FrameProfiler in prismarine_debug.

  heap  takes a heap snapshot of the isolate group at the time and groups
        the objects of the chosen classes by the path that retains them,
        the largest total first. The path is the first one from the roots
        that a breadth-first walk finds.
  live  prints the bytes and instances of each chosen class at each time.

The allocation profile of the VM gives no allocation rate. On Dart 3.13
`accumulatedSize` equals `bytesCurrent` and `reset: true` does not clear
it. Its MB per window are the contents of the heap, which `live` shows over
time. Allocation rates come from GC statistics, such as `--verbose_gc` or
the GC events of the timeline, or from allocation traces.

  dart run tools/profiler/bin/heap_report.dart heap <ws> <frames.jsonl> <t>
      [--classes=_Uint8List,_ByteDataView] [--min=<bytes>] [--max=<bytes>]
      [--depth=<n>] [--isolate=main] [--top=<n>]
  dart run tools/profiler/bin/heap_report.dart live <ws> <frames.jsonl>
      <class,class…> <t>…
''';

/// The game time of the last frame in [path], or null before the first one.
double? lastT(String path) {
  try {
    final s = File(path).readAsStringSync();
    for (final l in s.split('\n').reversed) {
      if (!l.startsWith('{') || !l.endsWith('}')) continue;
      final m = jsonDecode(l) as Map;
      if (m['t'] is num) return (m['t'] as num).toDouble();
    }
  } on Object {
    // The file does not exist yet.
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
  // The first referrer of each object on a breadth-first walk from the root,
  // object 1, and the index of its reference to the object.
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
      // The field of the referrer at the reference index. List elements and
      // other slots show as [].
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
