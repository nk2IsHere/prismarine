// The dominator tree and the retained sizes of a heap snapshot in flat typed
// lists. The snapshot of a game can hold tens of millions of objects.
import 'dart:typed_data';

import 'package:vm_service/vm_service.dart';

/// The dominator tree of [graph] from its root, object 1, by the algorithm of
/// Lengauer and Tarjan with path compression and without recursion.
/// [retained] sums the shallow size and the external memory of each object
/// over the objects that it dominates. The external memory is the size that
/// finalizers report, such as for the buffers and textures of Flutter GPU.
final class HeapDominators {
  HeapDominators(this.graph) {
    final objs = graph.objects;
    final n = objs.length;
    shallow = Int64List(n);
    for (var i = 1; i < n; i++) {
      shallow[i] = objs[i].shallowSize;
    }
    external = Int64List(n);
    for (final p in graph.externalProperties) {
      if (p.object > 0 && p.object < n) external[p.object] += p.externalSize;
    }
    _build(objs);
  }

  final HeapSnapshotGraph graph;
  late final Int64List shallow;
  late final Int64List external;

  /// The immediate dominator of each object. It is 0 for the root and for an
  /// object that the root does not reach.
  late final Uint32List idom;

  /// The retained size of each object. It is the size and the external memory
  /// of the object and of every object that it dominates.
  late final Int64List retained;

  /// The objects that the root reaches, in depth-first order.
  late final Uint32List order;

  /// The referrers of object v among the reached objects are [preds] from
  /// [predStart][v] to [predStart][v + 1].
  late final Uint32List predStart;
  late final Uint32List preds;

  /// The children of object v in the dominator tree are [kids] from
  /// [kidStart][v] to [kidStart][v + 1].
  late final Uint32List kidStart;
  late final Uint32List kids;

  /// The reference slots of each class that hold weakly, such as the target
  /// of a weak reference or a finalizer entry and the key of a weak property.
  /// An object that only these slots reach is garbage that the next old-space
  /// collection frees. The value of a weak property, such as an entry of an
  /// Expando, holds only while another path reaches its key.
  late final List<Set<int>?> _weak = [
    for (final c in graph.classes)
      switch (c.name) {
        '_WeakProperty' => _slots(c, const {'key_', 'value_'}),
        '_WeakReference' => _slots(c, const {'target_', '_target'}),
        'FinalizerEntry' => _slots(c, const {'value', 'detach'}),
        _ => null,
      },
  ];

  late final List<(int, int)?> _ephemeron = [
    for (final c in graph.classes)
      if (c.name == '_WeakProperty')
        (
          c.fields.firstWhere((f) => f.name == 'key_').index,
          c.fields.firstWhere((f) => f.name == 'value_').index,
        )
      else
        null,
  ];

  static Set<int>? _slots(HeapSnapshotClass c, Set<String> names) {
    final out = {
      for (final f in c.fields)
        if (names.contains(f.name)) f.index,
    };
    return out.isEmpty ? null : out;
  }

  /// Flags each object that strong references reach. The value of a weak
  /// property counts once its key is reached.
  late final Uint8List _live = () {
    final objs = graph.objects;
    final n = objs.length;
    final live = Uint8List(n);
    final waiting = <int, List<int>>{};
    final queue = Uint32List(n);
    var head = 0, tail = 0;
    void reach(int w) {
      if (w <= 0 || w >= n || live[w] != 0) return;
      live[w] = 1;
      queue[tail++] = w;
      final vs = waiting.remove(w);
      if (vs != null) vs.forEach(reach);
    }

    reach(1);
    while (head < tail) {
      final v = queue[head++];
      final o = objs[v];
      final e = _ephemeron[o.classId];
      final r = o.references;
      if (e != null) {
        final key = e.$1 < r.length ? r[e.$1] : 0;
        final value = e.$2 < r.length ? r[e.$2] : 0;
        if (key > 0 && key < n && live[key] == 0) {
          (waiting[key] ??= []).add(value);
        } else {
          reach(value);
        }
      }
      for (final w in strong(o, ephemerons: false)) {
        reach(w);
      }
    }
    return live;
  }();

  /// Returns the strong references of [o]. With [ephemerons] the value of a
  /// weak property counts when its key is live.
  Uint32List strong(HeapSnapshotObject o, {bool ephemerons = true}) {
    final r = o.references;
    final w = o.classId < _weak.length ? _weak[o.classId] : null;
    if (w == null) return r;
    final e = _ephemeron[o.classId];
    final out = <int>[
      for (var j = 0; j < r.length; j++)
        if (!w.contains(j)) r[j],
    ];
    if (ephemerons && e != null && e.$2 < r.length) {
      final key = e.$1 < r.length ? r[e.$1] : 0;
      if (key > 0 && key < _live.length && _live[key] != 0) out.add(r[e.$2]);
    }
    return Uint32List.fromList(out);
  }

  void _build(List<HeapSnapshotObject> objs) {
    final n = objs.length;
    // Numbers the objects depth first from the root, from 1. 0 marks an
    // object that the walk has not seen.
    final num = Uint32List(n);
    final parent = Uint32List(n);
    final vertex = Uint32List(n + 1);
    var count = 0;
    final stack = Uint32List(n + 1);
    final edge = Uint32List(n);
    var sp = 0;
    num[1] = ++count;
    vertex[count] = 1;
    stack[sp++] = 1;
    final refs = List<Uint32List?>.filled(n, null);
    while (sp > 0) {
      final v = stack[sp - 1];
      final r = refs[v] ??= strong(objs[v]);
      if (edge[v] >= r.length) {
        refs[v] = null;
        sp--;
        continue;
      }
      final w = r[edge[v]++];
      if (w <= 0 || w >= n || num[w] != 0) continue;
      num[w] = ++count;
      vertex[count] = w;
      parent[w] = v;
      stack[sp++] = w;
    }
    order = Uint32List.sublistView(vertex, 1, count + 1);
    // The referrers of the reached objects as compressed sparse rows.
    final predStart = Uint32List(n + 1);
    for (var i = 1; i <= count; i++) {
      final v = vertex[i];
      for (final w in strong(objs[v])) {
        if (w > 0 && w < n) predStart[w + 1]++;
      }
    }
    for (var i = 1; i <= n; i++) {
      predStart[i] += predStart[i - 1];
    }
    final preds = this.preds = Uint32List(predStart[n]);
    this.predStart = predStart;
    final fill = Uint32List.fromList(predStart);
    for (var i = 1; i <= count; i++) {
      final v = vertex[i];
      for (final w in strong(objs[v])) {
        if (w > 0 && w < n) preds[fill[w]++] = v;
      }
    }
    // semi[v] holds the semidominator's depth-first number.
    final semi = Uint32List(n);
    final label = Uint32List(n);
    final ancestor = Uint32List(n);
    final dom = Uint32List(n);
    final bucketHead = Uint32List(n);
    final bucketNext = Uint32List(n);
    for (var i = 1; i <= count; i++) {
      final v = vertex[i];
      semi[v] = i;
      label[v] = v;
    }
    final path = Uint32List(n);
    int eval(int v) {
      if (ancestor[v] == 0) return v;
      // Compress the ancestor chain above v.
      var len = 0;
      var x = v;
      while (ancestor[ancestor[x]] != 0) {
        path[len++] = x;
        x = ancestor[x];
      }
      while (len > 0) {
        final y = path[--len];
        final a = ancestor[y];
        if (semi[label[a]] < semi[label[y]]) label[y] = label[a];
        ancestor[y] = ancestor[a];
      }
      return label[v];
    }

    for (var i = count; i >= 2; i--) {
      final w = vertex[i];
      for (var k = predStart[w]; k < predStart[w + 1]; k++) {
        final v = preds[k];
        if (num[v] == 0) continue;
        final u = eval(v);
        if (semi[u] < semi[w]) semi[w] = semi[u];
      }
      final s = vertex[semi[w]];
      bucketNext[w] = bucketHead[s];
      bucketHead[s] = w;
      final p = parent[w];
      ancestor[w] = p;
      for (var v = bucketHead[p]; v != 0; v = bucketNext[v]) {
        final u = eval(v);
        dom[v] = semi[u] < semi[v] ? u : p;
      }
      bucketHead[p] = 0;
    }
    for (var i = 2; i <= count; i++) {
      final w = vertex[i];
      if (dom[w] != vertex[semi[w]]) dom[w] = dom[dom[w]];
    }
    dom[1] = 0;
    idom = dom;
    final ret = Int64List(n);
    for (var i = count; i >= 1; i--) {
      final v = vertex[i];
      ret[v] += shallow[v] + external[v];
      if (i > 1) ret[dom[v]] += ret[v];
    }
    retained = ret;
    final ks = Uint32List(n + 1);
    for (var i = 2; i <= count; i++) {
      ks[dom[vertex[i]] + 1]++;
    }
    for (var i = 1; i <= n; i++) {
      ks[i] += ks[i - 1];
    }
    final kidList = Uint32List(count);
    final at = Uint32List.fromList(ks);
    for (var i = 2; i <= count; i++) {
      final v = vertex[i];
      kidList[at[dom[v]]++] = v;
    }
    kidStart = ks;
    kids = kidList;
  }

  /// Returns the field of [holder] that references [child] directly. Returns
  /// null when no field of [holder] references it or its slot has no name.
  String? fieldName(int holder, int child) {
    final objs = graph.objects;
    final r = objs[holder].references;
    final fields = graph.classes[objs[holder].classId].fields;
    for (var j = 0; j < r.length; j++) {
      if (r[j] != child) continue;
      for (final f in fields) {
        if (f.index == j) return f.name;
      }
      return null;
    }
    return null;
  }
}
