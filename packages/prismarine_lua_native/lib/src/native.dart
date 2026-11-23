@ffi.DefaultAsset('package:prismarine_lua_native/src/native.dart')
library;

import 'dart:ffi' as ffi;

/// `mcsm_luac_compile` (native/src/lib.rs).
@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<ffi.Uint8>,
    ffi.Size,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
    ffi.Pointer<ffi.Size>,
  )
>(symbol: 'mcsm_luac_compile')
external int luacCompile(
  ffi.Pointer<ffi.Uint8> src,
  int len,
  ffi.Pointer<ffi.Uint8> name,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>> out,
  ffi.Pointer<ffi.Size> outLen,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(symbol: 'mcsm_luac_free')
external void luacFree(ffi.Pointer<ffi.Void> p);
