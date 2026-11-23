// Names for program elements that stay the same across analysis contexts (a
// library resolved from two packages has two element objects).
import 'package:analyzer/dart/element/element.dart';

/// `<library uri>::<Class>` for a class, mixin, enum, extension or extension
/// type; null for anything else.
String? classId(Element? e) {
  if (e is! InstanceElement) return null;
  final lib = e.library.uri;
  return '$lib::${e.name ?? ''}';
}

/// `<library uri>::<Class>.<member>` (a getter `get:<name>`, a setter
/// `set:<name>`, the unnamed constructor `new`) or `<library uri>::<name>`
/// for a top-level function, getter or setter; null for local functions and
/// anything that is not executable.
String? memberId(Element? element) {
  if (element is! ExecutableElement) return null;
  final e = element.baseElement;
  if (e is LocalFunctionElement) return null;
  final lib = e.library.uri;
  final owner = e.enclosingElement;
  final prefix = owner is InstanceElement ? '${owner.name ?? ''}.' : '';
  return '$lib::$prefix${memberName(e)}';
}

/// A member's name within its class, as [memberId] writes it.
String memberName(ExecutableElement e) {
  final name = e.name ?? '';
  if (e is ConstructorElement) return name.isEmpty ? 'new' : name;
  if (e is GetterElement) return 'get:$name';
  if (e is SetterElement) return 'set:$name';
  return name;
}

/// Whether [e] is declared in the SDK.
bool inSdk(Element e) => e.library?.uri.isScheme('dart') ?? false;
