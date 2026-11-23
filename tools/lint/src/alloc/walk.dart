// The code that the roots reach and the allocation places in it.
import 'package:analyzer/dart/ast/ast.dart';

import 'markers.dart';
import 'program.dart';
import 'sdk.dart';
import 'sites.dart';

/// A place that allocates, in reachable code.
class Hit {
  Hit(this.kind, this.file, this.line, this.column, this.what, this.inside)
    : accepted = null;
  Hit.accepted(
    this.kind,
    this.file,
    this.line,
    this.column,
    this.what,
    this.inside,
    this.accepted,
  );
  final String kind;
  final SourceFile file;
  final int line, column;
  final String what;

  /// The function that holds it.
  final String inside;

  /// The reason of its `// alloc:` marker, if any.
  final String? accepted;

  String get place => '${file.path}:$line:$column';
}

class Walk {
  Walk(this.program, this.sdk);
  final Program program;
  final SdkVerdicts sdk;

  /// Each reached function with the function that first reached it, or null
  /// for a root.
  final from = <String, String?>{};
  final hits = <Hit>[];

  /// The functions where the walk stopped, with their reasons.
  final cold = <String, String>{};

  /// The calls to members of the code of the repository without a body in
  /// the program. These members are abstract without a loaded override or
  /// outside the files in scope.
  final unresolved = <String>{};
  final _queue = <String>[];
  final _seen = <String>{};
  final _classesSeen = <String>{};

  void run(Iterable<String> roots) {
    for (final r in roots) {
      _reach(r, null);
    }
    while (_queue.isNotEmpty) {
      _visit(_queue.removeLast());
    }
  }

  void _reach(String id, String? via) {
    if (from.containsKey(id)) return;
    from[id] = via;
    _queue.add(id);
  }

  void _visit(String id) {
    final decl = program.decls[id];
    if (decl == null) {
      _implicitCtor(id);
      return;
    }
    final markers = Markers.of(decl.file);
    final reason = markers.cold(decl.line);
    if (reason != null) {
      cold[id] = reason;
      return;
    }
    _class(decl.owner, id);
    final setup = markers.setup(decl.line) != null;
    _readIn(decl.node, decl.file, id, markers, setup: setup);
    for (final init in decl.fieldInits) {
      _readIn(init, decl.file, id, markers);
    }
    // A generative constructor without a super initializer runs the unnamed
    // constructor of the superclass.
    final node = decl.node;
    if (node is ConstructorDeclaration &&
        node.factoryKeyword == null &&
        !node.initializers.any(
          (i) =>
              i is SuperConstructorInvocation ||
              i is RedirectingConstructorInvocation,
        )) {
      final s = program.superclass[decl.owner];
      if (s != null) _reach('$s.new', id);
    }
  }

  void _implicitCtor(String id) {
    if (!id.endsWith('.new')) {
      if (!id.startsWith('dart:')) unresolved.add(id);
      return;
    }
    final cid = id.substring(0, id.length - 4);
    final inits = program.implicitCtors[cid];
    final file = program.implicitCtorFiles[cid];
    if (inits == null || file == null) return;
    _class(cid, id);
    final markers = Markers.of(file);
    for (final init in inits) {
      _readIn(init, file, id, markers);
    }
    final s = program.superclass[cid];
    if (s != null) _reach('$s.new', id);
  }

  /// Marks the class [cid] as reached from [via]. The functions whose
  /// tear-offs its fields keep are reachable too.
  void _class(String? cid, String via) {
    if (cid == null || !_classesSeen.add(cid)) return;
    for (final t in program.classTearOffs[cid] ?? const <String>{}) {
      _reach(t, via);
    }
  }

  void _readIn(
    AstNode node,
    SourceFile file,
    String id,
    Markers markers, {
    bool setup = false,
  }) {
    final found = sitesOf(node, sdk, setup: setup);
    for (final s in found.sites) {
      // A field initializer is read once per constructor that runs it.
      if (!_seen.add('${file.path}:${s.offset}:${s.kind}:${s.what}')) continue;
      final line = file.lineOf(s.offset);
      final reason = markers.accepted(line);
      hits.add(
        reason == null
            ? Hit(s.kind, file, line, file.columnOf(s.offset), s.what, id)
            : Hit.accepted(
                s.kind,
                file,
                line,
                file.columnOf(s.offset),
                s.what,
                id,
                reason,
              ),
      );
    }
    for (final c in found.calls) {
      final on = c.onClass, name = c.name;
      if (on != null && name != null) {
        var any = false;
        for (final impl in program.implementations(on, name)) {
          any = true;
          _reach(impl, id);
        }
        // The member that the class of the receiver inherits.
        if (program.decls.containsKey(c.target)) {
          _reach(c.target, id);
        } else if (!any) {
          unresolved.add(c.target);
        }
      } else {
        _reach(c.target, id);
      }
    }
    for (final t in found.tearOffs) {
      _reach(t, id);
    }
  }

  /// Returns the chain of functions from a root to [id], root first.
  List<String> chain(String id) {
    final out = <String>[];
    String? at = id;
    while (at != null) {
      out.add(at);
      at = from[at];
    }
    return out.reversed.toList();
  }
}
