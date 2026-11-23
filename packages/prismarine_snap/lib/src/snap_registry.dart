// Closure recipes and the registry of codecs and closure factories.
part of 'snap.dart';

/// Makes a function again from its recipe's arguments.
typedef SnapFnFactory = Function Function(List<Object?> args);

final _recipes = Expando<(String, List<Object?>)>('snap fn recipe');

/// [fn] with its recipe: a snapshot writes the closure as [kind] and
/// [args], and the reader makes it again with the factory registered for
/// [kind] ([SnapRegistry.fn]). Every closure kept in game state is made
/// through one of these (a closure without a recipe can't be written).
F snapFn<F extends Function>(F fn, String kind, List<Object?> args) {
  _recipes[fn] = (kind, args);
  return fn;
}

/// The recipe [snapFn] gave [fn], if any.
(String, List<Object?>)? snapFnRecipe(Function fn) => _recipes[fn];

/// The codecs and closure factories a snapshot knows.
class SnapRegistry {
  final _byType = HashMap<Type, SnapCodec>();
  final _byTag = <String, SnapCodec>{};
  final _fns = <String, SnapFnFactory>{};

  /// Adds [codec] for objects whose runtime type is [type] (default: the
  /// codec's own type argument).
  void add<T extends Object>(SnapCodec<T> codec, {Type? type}) {
    final t = type ?? T;
    if (_byTag.containsKey(codec.tag) && !identical(_byTag[codec.tag], codec)) {
      throw SnapError('codec tag ${codec.tag} registered twice');
    }
    _byType[t] = codec;
    _byTag[codec.tag] = codec;
  }

  /// [add] for a codec of functions.
  void codec<T extends Object>(
    String tag, {
    void Function(SnapWriter w, T o)? writeNew,
    T Function(SnapReader r)? make,
    void Function(SnapWriter w, T o)? write,
    void Function(SnapReader r, T o)? read,
    Type? type,
  }) => add<T>(
    FnCodec<T>(tag, writeNew: writeNew, make: make, write: write, read: read),
    type: type,
  );

  /// The factory for closures made by `snapFn(…, kind, …)`.
  void fn(String kind, SnapFnFactory factory) {
    if (_fns.containsKey(kind)) throw SnapError('fn $kind registered twice');
    _fns[kind] = factory;
  }

  /// Where an object the reader has in its own data came from (a value
  /// the slice's manifest holds, shared by a property set): its kind and
  /// arguments, or null. Asked for each container before it is written.
  (String, List<Object?>)? Function(SnapWriter w, Object o)? originOf;

  /// Finds the object an origin names, in the reader's data.
  Object Function(SnapReader r, String kind, List<Object?> args)? resolveOrigin;

  /// Whether a container [originOf] names was changed in place since its
  /// origin made it: the writer then writes its content too, and the reader
  /// puts it into its own copy ([patchedOrigin] after).
  bool Function(Object o)? originChanged;

  /// Called with the reader's copy of an origin it patched.
  void Function(Object o)? patchedOrigin;

  SnapCodec? codecOf(Object o) => _byType[o.runtimeType];
  SnapCodec? codecFor(Type t) => _byType[t];
  SnapCodec? codecByTag(String tag) => _byTag[tag];
  SnapFnFactory? factoryOf(String kind) => _fns[kind];
}
