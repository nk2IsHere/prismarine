@ffi.DefaultAsset('package:prismarine_lua_native/src/native64.dart')
library;

import 'dart:ffi' as ffi;

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<ffi.Uint8>,
    ffi.Size,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
    ffi.Pointer<ffi.Size>,
  )
>(symbol: 'prismarine_luac64_compile')
external int luacCompile64(
  ffi.Pointer<ffi.Uint8> src,
  int len,
  ffi.Pointer<ffi.Uint8> name,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> out,
  ffi.Pointer<ffi.Size> outLen,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'prismarine_luac64_free',
)
external void luacFree64(ffi.Pointer<ffi.Void> p);
