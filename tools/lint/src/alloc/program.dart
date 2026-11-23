// The resolved program that the allocation lint walks. It holds every
// function with a body in the files in scope by a stable id, with the class
// hierarchy that gives the overrides an instance call can reach.
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';

import 'ids.dart';

/// One file as resolved.
class SourceFile {
  SourceFile(this.path, this.package, this.unit, this.lines, this.text);

  /// The path relative to the repository root.
  final String path;
  final String package;
  final CompilationUnit unit;
  final LineInfo lines;
  final String text;

  int lineOf(int offset) => lines.getLocation(offset).lineNumber;
  int columnOf(int offset) => lines.getLocation(offset).columnNumber;
}

/// A function, method, getter, setter or constructor with code to walk.
class Decl {
  Decl(this.id, this.file, this.node, this.owner, {this.fieldInits = const []});
  final String id;
  final SourceFile file;

  /// The declaration with its body and, for a constructor, its initializers.
  final AstNode node;

  /// The id of the enclosing class, if any.
  final String? owner;

  /// The field initializers of its class, which a generative constructor
  /// also runs.
  final List<Expression> fieldInits;

  int get line => file.lineOf(node.offset);
}

class Program {
  final files = <String, SourceFile>{};
  final decls = <String, Decl>{};

  /// The ids of the supertypes of each class along the whole chain, without
  /// the class itself.
  final supers = <String, Set<String>>{};

  /// Maps a member name, as in an id, to the classes that declare it.
  final declaring = <String, List<String>>{};

  /// The classes without a declared constructor, whose `Class.new` runs
  /// only their field initializers.
  final implicitCtors = <String, List<Expression>>{};
  final implicitCtorFiles = <String, SourceFile>{};
  final classNodes = <String, AstNode>{};

  /// The superclass of each class, for the implicit `super()` of a
  /// constructor.
  final superclass = <String, String>{};

  /// The functions torn off in the field initializers of a class. These kept
  /// tear-offs are reachable once the class has reachable code.
  final classTearOffs = <String, Set<String>>{};

  /// Every id declared in [classId].
  final members = <String, List<String>>{};

  /// Returns the overrides of [member], a name as in an id, in subtypes of
  /// [ofClass] and the member of [ofClass] itself.
  Iterable<String> implementations(String ofClass, String member) sync* {
    for (final c in declaring[member] ?? const <String>[]) {
      if (c == ofClass || (supers[c]?.contains(ofClass) ?? false)) {
        yield '$c.$member';
      }
    }
  }
}

/// Resolves every `.dart` file of the absolute [paths] into [program]. A file
/// that fails to resolve is reported through [warn].
Future<void> loadProgram(
  Program program,
  String root,
  List<String> paths,
  String Function(String relative) packageOf,
  void Function(String) warn,
) async {
  final collection = AnalysisContextCollection(includedPaths: paths);
  for (final context in collection.contexts) {
    final analyzed = context.contextRoot.analyzedFiles().toList()..sort();
    for (final path in analyzed) {
      if (!path.endsWith('.dart')) continue;
      final result = await context.currentSession.getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        warn('not resolved: $path');
        continue;
      }
      final relative = path.startsWith('$root/')
          ? path.substring(root.length + 1)
          : path;
      if (program.files.containsKey(relative)) continue;
      final file = SourceFile(
        relative,
        packageOf(relative),
        result.unit,
        result.lineInfo,
        result.content,
      );
      program.files[relative] = file;
      _index(program, file);
    }
  }
}

void _index(Program p, SourceFile file) {
  for (final d in file.unit.declarations) {
    if (d is FunctionDeclaration) {
      final id = memberId(d.declaredFragment?.element);
      if (id != null && d.functionExpression.body is! EmptyFunctionBody) {
        p.decls[id] = Decl(id, file, d, null);
      }
    } else if (d is ClassDeclaration) {
      _indexClass(p, file, d, d.declaredFragment?.element, d.body.members);
    } else if (d is MixinDeclaration) {
      _indexClass(p, file, d, d.declaredFragment?.element, d.body.members);
    } else if (d is EnumDeclaration) {
      _indexClass(p, file, d, d.declaredFragment?.element, d.body.members);
    } else if (d is ExtensionDeclaration) {
      _indexClass(p, file, d, d.declaredFragment?.element, d.body.members);
    } else if (d is ExtensionTypeDeclaration) {
      _indexClass(p, file, d, d.declaredFragment?.element, d.body.members);
    }
  }
}

void _indexClass(
  Program p,
  SourceFile file,
  AstNode node,
  InstanceElement? element,
  List<ClassMember> members,
) {
  final cid = classId(element);
  if (cid == null) return;
  p.classNodes[cid] = node;
  if (element is InterfaceElement) {
    p.supers[cid] = {
      for (final t in element.allSupertypes) ?classId(t.element),
    };
    final s = classId(element.supertype?.element);
    if (s != null) p.superclass[cid] = s;
  }
  final inits = <Expression>[];
  final tearOffs = <String>{};
  for (final m in members) {
    if (m is! FieldDeclaration) continue;
    for (final v in m.fields.variables) {
      final init = v.initializer;
      if (init == null) continue;
      // The tear-off of a field is made once and kept, a late or static one
      // on first use. Its target runs wherever the field is called.
      init.accept(_TearOffs(tearOffs));
      // Only the initializer of a plain instance field runs in constructors.
      if (!m.isStatic && !m.fields.isLate) inits.add(init);
    }
  }
  if (tearOffs.isNotEmpty) p.classTearOffs[cid] = tearOffs;
  var hasCtor = false;
  final ids = p.members[cid] = <String>[];
  for (final m in members) {
    if (m is MethodDeclaration) {
      final e = m.declaredFragment?.element;
      final id = memberId(e);
      if (id == null || e == null) continue;
      p.declaring.putIfAbsent(memberName(e), () => []).add(cid);
      if (m.body is EmptyFunctionBody) continue;
      p.decls[id] = Decl(id, file, m, cid);
      ids.add(id);
    } else if (m is ConstructorDeclaration) {
      hasCtor = true;
      final e = m.declaredFragment?.element;
      final id = memberId(e);
      if (id == null || e == null) continue;
      final generative = m.factoryKeyword == null;
      final redirects = m.initializers.any(
        (i) => i is RedirectingConstructorInvocation,
      );
      p.decls[id] = Decl(
        id,
        file,
        m,
        cid,
        fieldInits: generative && !redirects ? inits : const [],
      );
      ids.add(id);
    }
  }
  if (!hasCtor) {
    p.implicitCtors[cid] = inits;
    p.implicitCtorFiles[cid] = file;
  }
}

/// Collects the functions that an expression tears off.
class _TearOffs extends RecursiveAstVisitor<void> {
  _TearOffs(this.out);
  final Set<String> out;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final e = node.element;
    if (e is ExecutableElement &&
        e is! PropertyAccessorElement &&
        !_isCallee(node)) {
      final id = memberId(e);
      if (id != null) out.add(id);
    }
  }
}

bool _isCallee(SimpleIdentifier node) {
  final parent = node.parent;
  if (parent is MethodInvocation && identical(parent.methodName, node)) {
    return true;
  }
  return false;
}
