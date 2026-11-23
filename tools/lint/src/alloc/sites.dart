// The allocation places of one function and the calls that it makes, read
// from its resolved syntax tree.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import 'ids.dart';
import 'sdk.dart';

class Site {
  Site(this.kind, this.offset, this.what);
  final String kind;
  final int offset;
  final String what;
}

class Call {
  Call(this.target, this.offset, {this.onClass, this.name});

  /// The member the call resolves to.
  final String target;
  final int offset;

  /// The class of the receiver of an instance call. The walk adds the
  /// overrides of the member in its subtypes.
  final String? onClass;
  final String? name;
}

class Found {
  final sites = <Site>[];
  final calls = <Call>[];

  /// The functions torn off here, reachable from wherever they are called.
  final tearOffs = <String>{};
}

/// Reads the declaration or field initializer [node] with the verdicts
/// [sdk]. With [setup] the function itself runs once and only the closures
/// that it makes run per frame. Only the code inside them then counts.
Found sitesOf(AstNode node, SdkVerdicts sdk, {bool setup = false}) {
  final found = Found();
  node.accept(_Sites(found, sdk, setup));
  return found;
}

class _Sites extends RecursiveAstVisitor<void> {
  _Sites(this.out, this.sdk, this.setup);
  final Found out;
  final SdkVerdicts sdk;
  final bool setup;

  /// The depth of the visit in closures.
  int _depth = 0;
  bool get _counts => !setup || _depth > 0;

  void _site(String kind, AstNode at, String what) {
    if (_counts) out.sites.add(Site(kind, at.offset, what));
  }

  // --- Code a frame does not run.

  @override
  void visitThrowExpression(ThrowExpression node) {}

  @override
  void visitAssertStatement(AssertStatement node) {}

  @override
  void visitAssertInitializer(AssertInitializer node) {}

  @override
  void visitComment(Comment node) {}

  @override
  void visitAnnotation(Annotation node) {}

  // --- Objects.

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final ctor = node.constructorName.element;
    if (!node.isConst) {
      _site('new', node, 'a new ${node.constructorName.type.name.lexeme}');
    }
    // An SDK constructor is the `new` that is already counted.
    if (ctor != null && !inSdk(ctor)) _call(ctor, node);
    _arguments(node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitListLiteral(ListLiteral node) {
    if (!node.isConst) _site('literal', node, 'a list literal');
    super.visitListLiteral(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    if (!node.isConst) {
      _site('literal', node, node.isMap ? 'a map literal' : 'a set literal');
    }
    super.visitSetOrMapLiteral(node);
  }

  @override
  void visitRecordLiteral(RecordLiteral node) {
    if (!node.isConst) _site('literal', node, 'a record');
    super.visitRecordLiteral(node);
  }

  // --- Strings.

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _site('string', node, 'a string interpolation');
    super.visitStringInterpolation(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final left = node.leftOperand.staticType;
    if (node.operator.type == TokenType.PLUS &&
        left != null &&
        left.isDartCoreString) {
      _site('string', node, 'string concatenation');
    } else {
      _call(node.element, node);
    }
    super.visitBinaryExpression(node);
  }

  // --- Closures.

  @override
  void visitFunctionExpression(FunctionExpression node) {
    final parent = node.parent;
    // A declaration's own function is not a closure literal.
    if (parent is FunctionDeclaration &&
        parent.parent is! FunctionDeclarationStatement) {
      super.visitFunctionExpression(node);
      return;
    }
    final captured = _Captures.of(node);
    if (!_counts) {
      // The closure of a setup function is made once and its body runs per
      // frame.
    } else if (parent is FunctionDeclaration) {
      // A local function is a closure when it captures.
      if (captured != null) {
        _site('closure', parent, 'a local function capturing $captured');
      }
    } else {
      _site(
        'closure',
        node,
        captured == null ? 'a closure' : 'a closure capturing $captured',
      );
    }
    _depth++;
    super.visitFunctionExpression(node);
    _depth--;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final e = node.element;
    if (e is GetterElement) {
      if (!node.inSetterContext() || node.inGetterContext()) _accessor(e, node);
    } else if (e is ExecutableElement && e is! SetterElement) {
      if (!_isCallee(node) && !node.inDeclarationContext()) _tearOff(e, node);
    }
  }

  void _tearOff(ExecutableElement e, AstNode at) {
    if (e is LocalFunctionElement) return;
    final id = memberId(e);
    if (id != null && _counts) out.tearOffs.add(id);
    if (e is MethodElement && !e.isStatic) {
      _site('closure', at, 'a tear-off of ${e.name}');
    }
  }

  void _accessor(PropertyAccessorElement e, AstNode at, {DartType? receiver}) {
    // The own getter or setter of a field is a load or a store.
    if (e.isOriginVariable) return;
    _call(e, at, receiver: receiver);
  }

  // --- Calls.

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final e = node.methodName.element;
    final target = node.realTarget;
    if (e is ExecutableElement &&
        e is! PropertyAccessorElement &&
        e is! LocalFunctionElement) {
      _call(e, node, receiver: target?.staticType);
      if (e.name == 'toString' && node.argumentList.arguments.isEmpty) {
        _site('string', node, 'toString');
      }
      if (inSdk(e) && const {'add', 'insert', 'fillRange'}.contains(e.name)) {
        for (final a in node.argumentList.arguments) {
          _stored(target?.staticType, a.argumentExpression, node);
        }
      }
    } else if (e is LocalFunctionElement) {
      // Its body is read where it is declared.
    } else if (target != null && target.staticType is DynamicType) {
      _site('dynamic', node, 'a dynamic call of ${node.methodName.name}');
    } else {
      // A called field, variable or getter of a function type.
      if (e is GetterElement) _accessor(e, node.methodName);
      _functionValueCall(node.argumentList, node.staticType, node);
    }
    _arguments(node.argumentList);
    target?.accept(this);
    node.typeArguments?.accept(this);
    node.argumentList.accept(this);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final e = node.element;
    if (e != null) {
      // A `call` on an object.
      _call(e, node, receiver: node.function.staticType);
    } else {
      _functionValueCall(node.argumentList, node.staticType, node);
    }
    _arguments(node.argumentList);
    super.visitFunctionExpressionInvocation(node);
  }

  /// A call through a function value passes and returns doubles boxed.
  void _functionValueCall(ArgumentList args, DartType? result, AstNode at) {
    for (final a in args.arguments) {
      final t = a.argumentExpression.staticType;
      if (t != null && t.isDartCoreDouble) {
        _site('box', a, 'a double passed to a function value');
        return;
      }
    }
    if (result != null && result.isDartCoreDouble) {
      _site('box', at, 'a double returned by a function value');
    }
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final e = node.propertyName.element;
    if (e is PropertyAccessorElement) {
      _accessor(e, node, receiver: node.realTarget.staticType);
    } else if (e is ExecutableElement) {
      _tearOff(e, node);
    } else if (e == null && node.realTarget.staticType is DynamicType) {
      _site('dynamic', node, 'a dynamic read of ${node.propertyName.name}');
    }
    node.target?.accept(this);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final e = node.identifier.element;
    if (e is PropertyAccessorElement) {
      _accessor(e, node, receiver: node.prefix.staticType);
    } else if (e is ExecutableElement) {
      _tearOff(e, node);
    }
    node.prefix.accept(this);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _call(node.element, node, receiver: node.realTarget.staticType);
    super.visitIndexExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _call(node.element, node);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _call(node.element, node);
    super.visitPostfixExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final write = node.writeElement;
    if (write is SetterElement) _accessor(write, node);
    _call(node.element, node);
    final left = node.leftHandSide;
    if (left is IndexExpression && node.operator.type == TokenType.EQ) {
      _stored(left.realTarget.staticType, node.rightHandSide, node);
    }
    final to = node.writeType;
    final from = node.rightHandSide.staticType;
    if (node.operator.type == TokenType.EQ &&
        from != null &&
        to != null &&
        _boxes(from, to) &&
        // The box of a local may not be made. The box of a field or an
        // element is.
        write is! LocalVariableElement &&
        write is! FormalParameterElement) {
      _site('box', node.rightHandSide, 'a double stored as ${_show(to)}');
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _call(node.element, node);
    _arguments(node.argumentList);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _call(node.element, node);
    _arguments(node.argumentList);
    super.visitRedirectingConstructorInvocation(node);
  }

  void _call(Element? element, AstNode at, {DartType? receiver}) {
    if (element is! ExecutableElement) return;
    final e = element.baseElement;
    if (e is LocalFunctionElement) return;
    final id = memberId(e);
    if (id == null || !_counts) return;
    if (inSdk(e)) {
      _sdkCall(e, id, at, receiver);
      return;
    }
    final fragment = e.firstFragment;
    if (fragment.isAsynchronous || fragment.isGenerator) {
      _site('async', at, 'a call of ${e.name} (async or a generator)');
    }
    final owner = e.enclosingElement;
    final instance =
        owner is InterfaceElement && !e.isStatic && e is! ConstructorElement;
    if (instance) {
      final on = receiver is InterfaceType ? receiver.element : owner;
      out.calls.add(
        Call(id, at.offset, onClass: classId(on), name: memberName(e)),
      );
    } else {
      out.calls.add(Call(id, at.offset));
    }
  }

  void _sdkCall(
    ExecutableElement e,
    String id,
    AstNode at,
    DartType? receiver,
  ) {
    final name = memberName(e);
    final on = <String>[];
    if (receiver is InterfaceType) {
      on.add(classId(receiver.element)!);
      for (final t in receiver.allSupertypes) {
        on.add(classId(t.element)!);
      }
    } else {
      final owner = e.enclosingElement;
      if (owner is InterfaceElement) {
        on.add(classId(owner)!);
        for (final t in owner.allSupertypes) {
          on.add(classId(t.element)!);
        }
      }
    }
    var verdict = sdk.of(id, name, on);
    // An integer's clamp stays an integer.
    if (verdict == 'box' && receiver != null && receiver.isDartCoreInt) {
      verdict = 'ok';
    }
    if (verdict == 'ok') return;
    final shown = id.substring(id.indexOf('::') + 2);
    if (verdict == null) {
      _site('sdk', at, '$shown (${e.library.uri}): not known to the lint');
    } else {
      _site(verdict, at, shown);
    }
  }

  /// Finds the doubles in [list] passed where the parameter is not a double.
  /// They are boxed. The declared type of the parameter decides in the code
  /// of the repository, where the `T` of a generic class holds a box. The
  /// type at the call decides for the SDK, where min and max of doubles stay
  /// unboxed.
  void _arguments(ArgumentList list) {
    for (final a in list.arguments) {
      final value = a.argumentExpression;
      final from = value.staticType;
      final p = a.correspondingParameter;
      if (from == null || p == null) continue;
      final to = inSdk(p) ? p.type : p.baseElement.type;
      if (_boxes(from, to)) {
        _site('box', value, 'a double passed as ${_show(to)}');
      }
    }
  }

  /// A double put into a collection that is not typed data is boxed.
  void _stored(DartType? collection, Expression value, AstNode at) {
    final from = value.staticType;
    if (from == null || !from.isDartCoreDouble) return;
    if (from.nullabilitySuffix == NullabilitySuffix.question) return;
    if (collection is! InterfaceType) return;
    final lib = collection.element.library.uri.toString();
    if (lib == 'dart:typed_data') return;
    if (!lib.startsWith('dart:')) return; // the parameter of the code decides
    _site('box', value, 'a double stored in ${_show(collection)}');
  }

  // --- Returns.

  @override
  void visitReturnStatement(ReturnStatement node) {
    _returned(node.expression, node);
    super.visitReturnStatement(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _returned(node.expression, node);
    super.visitExpressionFunctionBody(node);
  }

  void _returned(Expression? value, AstNode at) {
    final from = value?.staticType;
    if (from == null || !from.isDartCoreDouble) return;
    final to = _returnTypeAround(at);
    if (to != null && _boxes(from, to)) {
      _site('box', value!, 'a double returned as ${_show(to)}');
    }
  }

  DartType? _returnTypeAround(AstNode at) {
    for (AstNode? n = at.parent; n != null; n = n.parent) {
      if (n is FunctionExpression) {
        return n.declaredFragment?.element.returnType;
      }
      if (n is MethodDeclaration) {
        return n.declaredFragment?.element.returnType;
      }
      if (n is ConstructorDeclaration) return null;
    }
    return null;
  }

  // --- Iteration and async.

  @override
  void visitForStatement(ForStatement node) {
    _forParts(node.forLoopParts);
    super.visitForStatement(node);
  }

  @override
  void visitForElement(ForElement node) {
    _forParts(node.forLoopParts);
    super.visitForElement(node);
  }

  void _forParts(ForLoopParts parts) {
    if (parts is! ForEachParts) return;
    final t = parts.iterable.staticType;
    if (t is InterfaceType && _isList(t)) return;
    _site('iterate', parts.iterable, 'for-in over ${_show(t)}: an iterator');
  }

  bool _isList(InterfaceType t) {
    bool list(InterfaceElement e) =>
        e.name == 'List' && e.library.uri.toString() == 'dart:core';
    return list(t.element) || t.allSupertypes.any((s) => list(s.element));
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    _site('async', node, 'an await');
    super.visitAwaitExpression(node);
  }

  // --- Helpers.

  bool _boxes(DartType from, DartType to) {
    if (!from.isDartCoreDouble) return false;
    if (from.nullabilitySuffix == NullabilitySuffix.question) return false;
    if (to.isDartCoreDouble) {
      return to.nullabilitySuffix == NullabilitySuffix.question;
    }
    return to is DynamicType ||
        to is TypeParameterType ||
        to.isDartCoreObject ||
        to.isDartCoreNum ||
        to is InterfaceType && to.element.name == 'Comparable';
  }

  String _show(DartType? t) => t?.getDisplayString() ?? 'an unknown type';
}

bool _isCallee(SimpleIdentifier node) {
  final parent = node.parent;
  return parent is MethodInvocation && identical(parent.methodName, node);
}

/// Finds the captures of a closure, a local of an enclosing function or
/// `this`.
class _Captures extends RecursiveAstVisitor<void> {
  _Captures(this.closure);
  final FunctionExpression closure;
  String? found;

  static String? of(FunctionExpression closure) {
    final v = _Captures(closure);
    closure.body.accept(v);
    return v.found;
  }

  bool _inside(Element e) {
    final offset = e.firstFragment.nameOffset ?? -1;
    return offset >= closure.offset && offset < closure.end;
  }

  @override
  void visitThisExpression(ThisExpression node) => found ??= 'this';

  @override
  void visitSuperExpression(SuperExpression node) => found ??= 'this';

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (found != null) return;
    final e = node.element;
    if (e is LocalVariableElement || e is FormalParameterElement) {
      if (!_inside(e!)) found = node.name;
    } else if (e is LocalFunctionElement) {
      if (!_inside(e)) found = node.name;
    } else if (e is ExecutableElement || e is FieldElement) {
      // An instance member used without a receiver reads `this`.
      final parent = node.parent;
      final qualified =
          parent is PropertyAccess && identical(parent.propertyName, node) ||
          parent is PrefixedIdentifier && identical(parent.identifier, node) ||
          parent is MethodInvocation &&
              identical(parent.methodName, node) &&
              parent.realTarget != null;
      final isStatic = e is ExecutableElement
          ? e.isStatic || e.enclosingElement is LibraryElement
          : (e as FieldElement).isStatic;
      if (!qualified && !isStatic && e!.enclosingElement is InstanceElement) {
        found = 'this';
      }
    }
  }
}
