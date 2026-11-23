// Closure recipes and the registry of codecs and closure factories.
part of 'snap.dart';

/// Makes a function again from the arguments of its recipe.
typedef SnapFnFactory = Function Function(List<Object?> args);

final _recipes = Expando<(String, List<Object?>)>('snap fn recipe');

/// Returns [fn] with its recipe. A snapshot writes the closure as [kind] and
/// [args]. The reader makes it again with the factory that [SnapRegistry.fn]
/// registered for [kind]. A closure in the state must be made with this
/// function, since a closure without a recipe cannot be written.
F snapFn<F extends Function>(F fn, String kind, List<Object?> args) {
  _recipes[fn] = (kind, args);
  return fn;
}

/// Returns the recipe that [snapFn] gave [fn], or null.
(String, List<Object?>)? snapFnRecipe(Function fn) => _recipes[fn];

/// The codecs and closure factories that a snapshot knows.
class SnapRegistry {
  final _byType = HashMap<Type, SnapCodec>();
  final _byTag = <String, SnapCodec>{};
  final _fns = <String, SnapFnFactory>{};

  /// Adds [codec] for objects whose runtime type is [type]. [type] defaults
  /// to the type argument of the codec.
  void add<T extends Object>(SnapCodec<T> codec, {Type? type}) {
    final t = type ?? T;
    if (_byTag.containsKey(codec.tag) && !identical(_byTag[codec.tag], codec)) {
      throw SnapError('codec tag ${codec.tag} registered twice');
    }
    _byType[t] = codec;
    _byTag[codec.tag] = codec;
  }

  /// Adds a [FnCodec] of the given functions.
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

  /// Registers [factory] for the closures that [snapFn] made with [kind].
  void fn(String kind, SnapFnFactory factory) {
    if (_fns.containsKey(kind)) throw SnapError('fn $kind registered twice');
    _fns[kind] = factory;
  }

  /// Returns the origin of an object that the reader has in its own data,
  /// such as a value of loaded data that several objects share. The origin
  /// is a kind with its arguments, or null. The writer calls it for each
  /// container before writing it.
  (String, List<Object?>)? Function(SnapWriter w, Object o)? originOf;

  /// Finds the object of an origin in the data of the reader.
  Object Function(SnapReader r, String kind, List<Object?> args)? resolveOrigin;

  /// Returns true when a container with an origin from [originOf] was
  /// changed in place after its origin made it. The writer then writes its
  /// content too. The reader puts the content into its own copy and calls
  /// [patchedOrigin].
  bool Function(Object o)? originChanged;

  /// Receives each copy of an origin that the reader patched.
  void Function(Object o)? patchedOrigin;

  SnapCodec? codecOf(Object o) => _byType[o.runtimeType];
  SnapCodec? codecFor(Type t) => _byType[t];
  SnapCodec? codecByTag(String tag) => _byTag[tag];
  SnapFnFactory? factoryOf(String kind) => _fns[kind];
}
