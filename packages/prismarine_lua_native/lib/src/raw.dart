import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// The raw result of `mcsm_luac_compile`: status 0 with the host-layout
/// dump, or 1/4 with the error text (bytes).
(int, Uint8List) compileRaw(List<int> source, List<int> chunkName) {
  // Lua strings are bytes: a code unit above 0xFF would be silently cut to
  // its low byte, so callers must encode text (UTF-8) first.
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
    final status = luacCompile(src, source.length, name, out, outLen);
    final p = out.value;
    final bytes = p == ffi.nullptr
        ? Uint8List(0)
        : Uint8List.fromList(p.asTypedList(outLen.value));
    if (p != ffi.nullptr) luacFree(p.cast());
    return (status, bytes);
  } finally {
    malloc
      ..free(src)
      ..free(name)
      ..free(out)
      ..free(outLen);
  }
}
