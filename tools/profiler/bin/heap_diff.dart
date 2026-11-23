// Compares heap snapshots by retaining path. --help prints the usage.
import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_profiler/heap_dominators.dart';
import 'package:vm_service/vm_service.dart';

const _usage = r'''
Compares heap snapshots by retaining path. The tool reads snapshot files,
such as the files of PRISMARINE_HEAP_SNAPSHOT in prismarine_debug or any
HeapSnapshotGraph of the VM service saved in one file. It builds the
dominator tree of each snapshot and groups the retained size of each object
by the path of classes and fields from the root to the object that
dominates it. The retained size includes external memory, such as the
buffers and textures of Flutter GPU and native blocks. The objects of one
class under one field form one group. The tool prints the groups above
--min MB in any snapshot side by side in tree order, then the largest
growths, then the classes and the external memory by holder class.

  dart run tools/profiler/bin/heap_diff.dart <a.dartheap> <b.dartheap>…
      [--min=<MB>] [--keep=<MB>] [--depth=<n>] [--top=<n>]
      [--who=<path end>]

--keep is the smallest group that is recorded, 0.5 by default. --min is the
smallest group that is printed, 4 by default. --depth is the deepest path,
40 by default. --top is the number of rows in each list, 60 by default.
--who prints the referrers of the members of each group whose path ends in
the text.
''';

String? _opt(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

final class _Group {
  _Group(this.order);
  final int order;
  final List<int> count = [];
  final List<int> bytes = [];
}

final class _Shot {
  _Shot(this.name);
  final String name;
  int objects = 0, reached = 0, external = 0, capacity = 0;
  final classBytes = <String, int>{};
  final classCount = <String, int>{};
  final externalBy = <String, int>{};
}

Future<void> main(List<String> args) async {
  final files = [
    for (final a in args)
      if (!a.startsWith('--')) a,
  ];
  if (args.contains('--help') || files.isEmpty) {
    stdout.write(_usage);
    exit(files.isEmpty && !args.contains('--help') ? 64 : 0);
  }
  final keep = (double.tryParse(_opt(args, 'keep') ?? '') ?? 0.5) * 1e6;
  final min = (double.tryParse(_opt(args, 'min') ?? '') ?? 4) * 1e6;
  final maxDepth = int.tryParse(_opt(args, 'depth') ?? '') ?? 40;
  final top = int.tryParse(_opt(args, 'top') ?? '') ?? 60;
  final groups = <String, _Group>{};
  final shots = <_Shot>[];
  for (var s = 0; s < files.length; s++) {
    final sw = Stopwatch()..start();
    final bytes = File(files[s]).readAsBytesSync();
    final g = HeapSnapshotGraph.fromChunks(
      [ByteData.sublistView(bytes)],
      calculateReferrers: false,
      decodeObjectData: true,
      decodeIdentityHashCodes: false,
    );
    final d = HeapDominators(g);
    stderr.writeln(
      '${files[s]}: ${g.objects.length} objects, read and dominated in '
      '${sw.elapsed.inSeconds} s',
    );
    final shot = _Shot(files[s].split('/').last)
      ..objects = g.objects.length
      ..reached = d.retained[1]
      ..capacity = g.capacity;
    shots.add(shot);
    _tally(g, d, shot);
    _walk(g, d, s, files.length, groups, keep, maxDepth, _opt(args, 'who'));
  }
  _print(shots, groups, min, top);
}

void _tally(HeapSnapshotGraph g, HeapDominators d, _Shot shot) {
  final objs = g.objects;
  final cls = g.classes;
  for (final v in d.order) {
    final c = cls[objs[v].classId];
    final k = '${c.name} (${c.libraryUri.toString().split('/').last})';
    shot.classBytes[k] = (shot.classBytes[k] ?? 0) + d.shallow[v];
    shot.classCount[k] = (shot.classCount[k] ?? 0) + 1;
    final e = d.external[v];
    if (e > 0) {
      shot.external += e;
      shot.externalBy[k] = (shot.externalBy[k] ?? 0) + e;
    }
  }
}

/// Groups the dominator tree by path. The children of the members of a
/// group are keyed by their class and by the field that holds them when the
/// member references them directly.
void _walk(
  HeapSnapshotGraph g,
  HeapDominators d,
  int shot,
  int shots,
  Map<String, _Group> groups,
  double keep,
  int maxDepth,
  String? who,
) {
  final objs = g.objects;
  final cls = g.classes;
  final fieldNames = List<Map<int, String>?>.filled(cls.length, null);
  final mark = Uint32List(objs.length);
  String fieldOf(int classId, int j) {
    final m = fieldNames[classId] ??= {
      for (final f in cls[classId].fields) f.index: f.name,
    };
    return m[j] ?? '';
  }

  void record(String path, int count, int bytes) {
    final grp = groups[path] ??= _Group(groups.length);
    while (grp.count.length < shots) {
      grp.count.add(0);
      grp.bytes.add(0);
    }
    grp.count[shot] += count;
    grp.bytes[shot] += bytes;
  }

  // The storage of an SDK collection is skipped, such as the backing _List
  // of a map or a growable list or the weak properties of an Expando. Its
  // entries are grouped under the collection.
  final sdk = [
    for (final c in cls) c.libraryUri.toString().startsWith('dart:'),
  ];
  bool through(int holder, int w) {
    if (!sdk[objs[holder].classId]) return false;
    final n = cls[objs[w].classId].name;
    return n == '_List' || n == '_WeakProperty';
  }

  // A closure gets the name of its function and a context the name of a
  // closure over it.
  String className(int c) {
    final o = objs[c];
    if (o.data is String) return o.data as String;
    for (final r in o.references) {
      if (r > 0 && r < objs.length && cls[objs[r].classId].name == 'Class') {
        return className(r);
      }
    }
    return '?';
  }

  // The name of a function with its class. A closure gets the name of the
  // parent function in its ClosureData.
  String qualified(int fn, int depth) {
    final name = objs[fn].data is String ? objs[fn].data as String : '?';
    for (final r in objs[fn].references) {
      if (r <= 0 || r >= objs.length) continue;
      final c = cls[objs[r].classId].name;
      if (c == 'ClosureData' && depth < 4) {
        for (final p in objs[r].references) {
          if (p > 0 &&
              p < objs.length &&
              cls[objs[p].classId].name == 'Function') {
            return '${qualified(p, depth + 1)}.<closure>';
          }
        }
      }
      if (c == 'Class' || c == 'PatchClass') return '${className(r)}.$name';
    }
    return name;
  }

  String? fnOf(int closure) {
    for (final r in objs[closure].references) {
      if (r <= 0 || r >= objs.length) continue;
      if (cls[objs[r].classId].name == 'Function') return qualified(r, 0);
    }
    return null;
  }

  String nameOf(int w) {
    final n = cls[objs[w].classId].name;
    if (n == '_Closure') return '_Closure(${fnOf(w) ?? '?'})';
    if (n != 'Context') return n;
    for (var i = d.predStart[w]; i < d.predStart[w + 1]; i++) {
      final p = d.preds[i];
      if (cls[objs[p].classId].name == '_Closure') {
        return 'Context(${fnOf(p) ?? '?'})';
      }
    }
    return n;
  }

  // Prints the referrers of the members of a group for --who as class.field
  // in each snapshot. A member counts once for each kind of referrer.
  void holders(List<int> members, String path) {
    final by = <String, int>{};
    for (final w in members) {
      final seen = <String>{};
      for (var i = d.predStart[w]; i < d.predStart[w + 1]; i++) {
        final p = d.preds[i];
        final r = objs[p].references;
        var f = '';
        for (var j = 0; j < r.length; j++) {
          if (r[j] == w) {
            f = fieldOf(objs[p].classId, j);
            break;
          }
        }
        // Follows the SDK collections up to the own object that holds them.
        var k = '${nameOf(p)}${f.isEmpty ? '' : '.$f'}';
        var q = p;
        for (var hop = 0; hop < 5 && sdk[objs[q].classId]; hop++) {
          if (d.predStart[q] == d.predStart[q + 1]) break;
          final up = d.preds[d.predStart[q]];
          final ur = objs[up].references;
          var uf = '';
          for (var j = 0; j < ur.length; j++) {
            if (ur[j] == q) {
              uf = fieldOf(objs[up].classId, j);
              break;
            }
          }
          k = '${nameOf(up)}${uf.isEmpty ? '' : '.$uf'} < $k';
          q = up;
        }
        if (seen.add(k)) by[k] = (by[k] ?? 0) + 1;
      }
    }
    final ks = by.keys.toList()..sort((a, b) => by[b]! - by[a]!);
    print('-- shot $shot holders of $path (${members.length}):');
    for (final k in ks.take(12)) {
      print('   ${by[k]}  $k');
    }
  }

  void visit(List<int> members, String path, int depth) {
    if (depth >= maxDepth) return;
    final by = <String, List<int>>{};
    final todo = [...members];
    while (todo.isNotEmpty) {
      final m = todo.removeLast();
      final r = objs[m].references;
      for (var j = 0; j < r.length; j++) {
        final w = r[j];
        if (w <= 0 || w >= objs.length || d.idom[w] != m || mark[w] == m) {
          continue;
        }
        mark[w] = m;
        if (through(m, w)) {
          todo.add(w);
          continue;
        }
        // The children of the root are keyed by slot, which keeps the
        // roots of each isolate apart.
        final f = m == 1 ? '#$j' : fieldOf(objs[m].classId, j);
        final k = '${f.isEmpty ? '' : '.$f:'}${nameOf(w)}';
        (by[k] ??= []).add(w);
      }
      for (var i = d.kidStart[m]; i < d.kidStart[m + 1]; i++) {
        final w = d.kids[i];
        if (mark[w] == m) continue;
        mark[w] = m;
        (by['~${nameOf(w)}'] ??= []).add(w);
      }
    }
    for (final e in by.entries) {
      var sum = 0;
      for (final w in e.value) {
        sum += d.retained[w];
      }
      if (sum < keep) continue;
      final p = '$path > ${e.key}';
      record(p, e.value.length, sum);
      if (who != null && p.endsWith(who)) holders(e.value, p);
      visit(e.value, p, depth + 1);
    }
  }

  record('root', 1, d.retained[1]);
  visit([1], 'root', 0);
}

String _mb(int b) => (b / 1e6).toStringAsFixed(1).padLeft(8);

void _print(
  List<_Shot> shots,
  Map<String, _Group> groups,
  double min,
  int top,
) {
  final n = shots.length;
  print('snapshots: ${[for (final s in shots) s.name].join(' | ')}');
  for (final s in shots) {
    print(
      '${s.name}: ${s.objects} objects, ${_mb(s.reached)} MB reached '
      '(external ${_mb(s.external)} MB), capacity ${_mb(s.capacity)} MB',
    );
  }
  int last(_Group g) => g.bytes.length < n ? 0 : g.bytes[n - 1];
  int first(_Group g) => g.bytes.isEmpty ? 0 : g.bytes[0];
  String row(_Group g, String path) {
    final b = [for (var i = 0; i < n; i++) i < g.bytes.length ? g.bytes[i] : 0];
    final c = [for (var i = 0; i < n; i++) i < g.count.length ? g.count[i] : 0];
    return '${b.map(_mb).join(' ')} ${_mb(last(g) - first(g))}  '
        '[${c.join(' ')}]  $path';
  }

  print('\n== retained by path (MB per snapshot, last − first, [counts])');
  final paths = groups.keys.where((p) {
    final g = groups[p]!;
    return g.bytes.any((b) => b >= min);
  }).toList()..sort();
  for (final p in paths) {
    print(row(groups[p]!, p));
  }
  print('\n== largest own growths (a group\'s growth less its groups\')');
  final own = <String, int>{};
  for (final p in groups.keys) {
    final g = groups[p]!;
    own[p] = (own[p] ?? 0) + last(g) - first(g);
    final i = p.lastIndexOf(' > ');
    if (i > 0) {
      final up = p.substring(0, i);
      own[up] = (own[up] ?? 0) - (last(g) - first(g));
    }
  }
  final owns = own.keys.toList()..sort((a, b) => own[b]!.compareTo(own[a]!));
  for (final p in owns.take(top)) {
    print('${_mb(own[p]!)}  ${row(groups[p]!, p)}');
  }
  print('\n== largest growths');
  final grow = groups.keys.toList()
    ..sort((a, b) {
      final ga = groups[a]!, gb = groups[b]!;
      return (last(gb) - first(gb)).compareTo(last(ga) - first(ga));
    });
  for (final p in grow.take(top)) {
    print(row(groups[p]!, p));
  }
  void table(String title, Map<String, int> Function(_Shot) of) {
    print('\n== $title (MB per snapshot, last − first)');
    final keys = <String>{for (final s in shots) ...of(s).keys}.toList();
    int v(int i, String k) => of(shots[i])[k] ?? 0;
    keys.sort(
      (a, b) => (v(n - 1, b) - v(0, b)).compareTo(v(n - 1, a) - v(0, a)),
    );
    for (final k in keys.take(top)) {
      final vs = [for (var i = 0; i < n; i++) v(i, k)];
      print('${vs.map(_mb).join(' ')} ${_mb(vs.last - vs.first)}  $k');
    }
  }

  table('classes, shallow', (s) => s.classBytes);
  table('external memory by holder class', (s) => s.externalBy);
  print('\n== class counts (per snapshot, last − first)');
  final keys = <String>{for (final s in shots) ...s.classCount.keys}.toList();
  int c(int i, String k) => shots[i].classCount[k] ?? 0;
  keys.sort((a, b) => (c(n - 1, b) - c(0, b)).compareTo(c(n - 1, a) - c(0, a)));
  for (final k in keys.take(top)) {
    final vs = [for (var i = 0; i < n; i++) c(i, k)];
    print('${vs.join(' ')} ${vs.last - vs.first}  $k');
  }
}
