import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native32.dart';
import 'native64.dart';

/// Compiles [source] as the chunk [chunkName] with the double build, or with
/// the float32 build when [float32]. Returns status 0 with the dump in the
/// layout of the host, or 1 for a syntax error and 4 for memory with the
/// error text as bytes.
(int, Uint8List) compileRaw(
  List<int> source,
  List<int> chunkName, {
  bool float32 = false,
}) {
  // Lua strings are bytes. A code unit above 0xFF would be cut to its low
  // byte, and callers must encode text, such as with UTF-8, first.
  for (final c in source) {
    if (c > 0xFF) {
      throw ArgumentError('source is not a byte string (code unit $c)');
    }
  }
  for (final c in chunkName) {
    if (c > 0xFF) {
      throw ArgumentError('chunk name is not a byte string (code unit $c)');
    }
  }
  final src = malloc<ffi.Uint8>(source.isEmpty ? 1 : source.length);
  final name = malloc<ffi.Uint8>(chunkName.length + 1);
  final out = malloc<ffi.Pointer<ffi.Uint8>>();
  final outLen = malloc<ffi.Size>();
  try {
    src.asTypedList(source.isEmpty ? 1 : source.length).setAll(0, source);
    name.asTypedList(chunkName.length + 1)
      ..setAll(0, chunkName)
      ..[chunkName.length] = 0;
    final status = float32
        ? luacCompile32(src, source.length, name, out, outLen)
        : luacCompile64(src, source.length, name, out, outLen);
    final p = out.value;
    final bytes = p == ffi.nullptr
        ? Uint8List(0)
        : Uint8List.fromList(p.asTypedList(outLen.value));
    if (p != ffi.nullptr) {
      float32 ? luacFree32(p.cast()) : luacFree64(p.cast());
    }
    return (status, bytes);
  } finally {
    malloc
      ..free(src)
      ..free(name)
      ..free(out)
      ..free(outLen);
  }
}
