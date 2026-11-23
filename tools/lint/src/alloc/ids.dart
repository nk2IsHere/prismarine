// Ids for program elements that stay the same across analysis contexts. A
// library resolved from two packages has two element objects.
import 'package:analyzer/dart/element/element.dart';

/// Returns `<library uri>::<Class>` for a class, mixin, enum, extension or
/// extension type. Returns null for anything else.
String? classId(Element? e) {
  if (e is! InstanceElement) return null;
  final lib = e.library.uri;
  return '$lib::${e.name ?? ''}';
}

/// Returns `<library uri>::<Class>.<member>` or, for a top-level function,
/// getter or setter, `<library uri>::<name>`. A getter has the member
/// `get:<name>`, a setter `set:<name>` and the unnamed constructor `new`.
/// Returns null for local functions and anything that is not executable.
String? memberId(Element? element) {
  if (element is! ExecutableElement) return null;
  final e = element.baseElement;
  if (e is LocalFunctionElement) return null;
  final lib = e.library.uri;
  final owner = e.enclosingElement;
  final prefix = owner is InstanceElement ? '${owner.name ?? ''}.' : '';
  return '$lib::$prefix${memberName(e)}';
}

/// Returns the name of a member within its class in the form of [memberId].
String memberName(ExecutableElement e) {
  final name = e.name ?? '';
  if (e is ConstructorElement) return name.isEmpty ? 'new' : name;
  if (e is GetterElement) return 'get:$name';
  if (e is SetterElement) return 'set:$name';
  return name;
}

/// Returns true when [e] is declared in the SDK.
bool inSdk(Element e) => e.library?.uri.isScheme('dart') ?? false;
