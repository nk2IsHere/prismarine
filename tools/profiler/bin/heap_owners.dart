// Sums the Dart heap of a running app by owner. --help prints the usage.
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'heap_report.dart' show lastT;

const _usage = r'''
Sums the Dart heap of a running app by owner. The tool attaches to the VM
service of a profile build. At each game time of the clock file, the
frames.jsonl of FrameProfiler in prismarine_debug, it takes a heap snapshot
of the isolate group and sums the shallow size of every object under its
owner. The owner is the child of the root above the object, which keeps the
roots of each isolate and of the group apart, followed by the first --depth
classes of own code on the first path from the roots that a breadth-first
walk finds. The tool also prints the largest classes.

  dart run tools/profiler/bin/heap_owners.dart <ws> <frames.jsonl> <t>…
      [--top=<n>] [--depth=<k>] [--fields] [--roots] [--classes-in=<text>]
      [--ours=<text>,…]

--ours lists texts. A class is own code when the URI of its library
contains one of them. Without --ours every class outside the dart: libraries
and package:flutter/ is own code. --depth is 2 by default and --top 40.
--fields adds the field of own code that holds SDK objects, such as a map or
a list. --roots adds the SDK classes on the first hops under the roots of an
isolate. --classes-in prints the largest classes under the owners whose
label ends in the text.
''';

String? _opt(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

Future<void> main(List<String> args) async {
  final pos = [
    for (final a in args)
      if (!a.startsWith('--')) a,
  ];
  if (args.contains('--help') || pos.length < 3) {
    stdout.write(_usage);
    exit(pos.length < 3 && !args.contains('--help') ? 64 : 0);
  }
  final top = int.tryParse(_opt(args, 'top') ?? '') ?? 40;
  final depth = int.tryParse(_opt(args, 'depth') ?? '') ?? 2;
  final fields = args.contains('--fields');
  final roots = args.contains('--roots');
  final classesIn = _opt(args, 'classes-in');
  final ours = _opt(args, 'ours')?.split(',');
  final vm = await vmServiceConnectUri(pos[0]);
  try {
    for (final t in pos.skip(2).map(double.parse)) {
      while ((lastT(pos[1]) ?? -1) < t) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _report(vm, pos[1], top, depth, fields, roots, classesIn, ours);
    }
  } finally {
    await vm.dispose();
  }
}

Future<void> _report(
  VmService vm,
  String frames,
  int top,
  int depth,
  bool fields,
  bool roots,
  String? classesIn,
  List<String>? oursIn,
) async {
  final isolates = (await vm.getVM()).isolates ?? const <IsolateRef>[];
  final iso = isolates.first;
  final sw = Stopwatch()..start();
  final g = await HeapSnapshotGraph.getSnapshot(vm, iso);
  final objs = g.objects;
  final cls = g.classes;
  final ours = [for (final c in cls) _isOurs(c.libraryUri.toString(), oursIn)];
  // Owner labels in breadth-first order. A child gets the label of its
  // parent, extended by its own class while the label holds fewer than
  // [depth] own classes.
  final labels = <String>[];
  final labelOf = <String, int>{};
  final ourCount = <int>[];
  int labelId(String s, int n) {
    final had = labelOf[s];
    if (had != null) return had;
    labels.add(s);
    ourCount.add(n);
    return labelOf[s] = labels.length - 1;
  }

  final owner = List<int>.filled(objs.length, -1);
  final hops = List<int>.filled(objs.length, 0);
  final parentOf = List<int>.filled(objs.length, -1);
  final bytes = <int, int>{};
  final queue = <int>[];
  final rootRefs = objs[1].references;
  for (var j = 0; j < rootRefs.length; j++) {
    final r = rootRefs[j];
    if (r <= 1 || r >= objs.length || owner[r] != -1) continue;
    owner[r] = labelId('root[$j] ${cls[objs[r].classId].name}', 0);
    queue.add(r);
  }
  for (var qi = 0; qi < queue.length; qi++) {
    final o = queue[qi];
    final lo = owner[o];
    final size = objs[o].shallowSize;
    bytes[lo] = (bytes[lo] ?? 0) + size;
    final refs = objs[o].references;
    for (var j = 0; j < refs.length; j++) {
      final r = refs[j];
      if (r <= 1 || r >= objs.length || owner[r] != -1) continue;
      final c = objs[r].classId;
      var l = lo;
      if (ours[c] && ourCount[lo] < depth) {
        l = labelId('${labels[lo]} > ${cls[c].name}', ourCount[lo] + 1);
      } else if (!ours[c] && ours[objs[o].classId] && fields) {
        // A field of own code that holds SDK objects, such as a map or a
        // list, gets a label of its own.
        var f = '[]';
        for (final x in cls[objs[o].classId].fields) {
          if (x.index == j) f = x.name;
        }
        l = labelId('${labels[lo]}.$f', ourCount[lo]);
      } else if (!ours[c] && roots && ourCount[lo] == 0 && hops[o] < 3) {
        // The SDK classes between the roots of an isolate and the first
        // own class, such as statics and message queues.
        l = labelId('${labels[lo]} / ${cls[c].name}', 0);
      }
      hops[r] = hops[o] + 1;
      parentOf[r] = o;
      owner[r] = l;
      queue.add(r);
    }
  }
  var total = 0;
  for (final b in bytes.values) {
    total += b;
  }
  print(
    '\n== t=${lastT(frames)?.toStringAsFixed(2)}: ${objs.length} objects, '
    '${(total / 1e6).toStringAsFixed(0)} MB reached '
    '(snapshot ${sw.elapsed.inSeconds} s)',
  );
  final keys = bytes.keys.toList()..sort((a, b) => bytes[b]! - bytes[a]!);
  for (final k in keys.take(top)) {
    print(
      '${(bytes[k]! / 1e6).toStringAsFixed(1).padLeft(8)} MB  ${labels[k]}',
    );
  }
  // The largest classes for --classes-in under the owners whose label ends
  // in the text, each with the class of the object that reached it first.
  if (classesIn != null) {
    final by = <String, int>{};
    for (var i = 1; i < objs.length; i++) {
      final l = owner[i];
      if (l < 0 || !labels[l].endsWith(classesIn)) continue;
      final p = parentOf[i];
      final k =
          '${cls[objs[i].classId].name} <- '
          '${p < 0 ? '?' : cls[objs[p].classId].name}';
      by[k] = (by[k] ?? 0) + objs[i].shallowSize;
    }
    final ks = by.keys.toList()..sort((a, b) => by[b]! - by[a]!);
    print('-- classes under "$classesIn"');
    for (final k in ks.take(25)) {
      print('${(by[k]! / 1e6).toStringAsFixed(1).padLeft(8)} MB  $k');
    }
  }
  // The largest classes over the whole group.
  final byClass = <int, int>{};
  for (var i = 1; i < objs.length; i++) {
    final c = objs[i].classId;
    byClass[c] = (byClass[c] ?? 0) + objs[i].shallowSize;
  }
  final cs = byClass.keys.toList()..sort((a, b) => byClass[b]! - byClass[a]!);
  print('-- classes');
  for (final c in cs.take(20)) {
    print(
      '${(byClass[c]! / 1e6).toStringAsFixed(1).padLeft(8)} MB  '
      '${cls[c].name} (${cls[c].libraryUri.toString().split('/').last})',
    );
  }
}

bool _isOurs(String library, List<String>? ours) => ours == null
    ? !library.startsWith('dart:') && !library.startsWith('package:flutter/')
    : ours.any(library.contains);
