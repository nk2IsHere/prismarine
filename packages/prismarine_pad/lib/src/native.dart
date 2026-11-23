/// The functions of the pad library, the Rust `cdylib` in native/ that the
/// build hook of the package builds.
@ffi.DefaultAsset('package:prismarine_pad/src/native.dart')
library;

import 'dart:ffi' as ffi;

/// The `PadReading` of native/src/lib.rs, returned by value.
final class NativePadReading extends ffi.Struct {
  @ffi.Uint8()
  external int connected;
  @ffi.Uint8()
  external int xbox;
  @ffi.Uint8()
  external int unavailable;
  @ffi.Uint8()
  external int reserved;
  @ffi.Uint32()
  external int buttons;
  @ffi.Float()
  external double leftX;
  @ffi.Float()
  external double leftY;
  @ffi.Float()
  external double rightX;
  @ffi.Float()
  external double rightY;
  @ffi.Float()
  external double leftTrigger;
  @ffi.Float()
  external double rightTrigger;
  @ffi.Array(64)
  external ffi.Array<ffi.Uint8> name;
}

@ffi.Native<NativePadReading Function()>(symbol: 'prismarine_pad_read')
external NativePadReading padRead();

/// The `PadDevice` of native/src/lib.rs, returned by value.
final class NativePadDevice extends ffi.Struct {
  @ffi.Uint8()
  external int present;
  @ffi.Array(3)
  external ffi.Array<ffi.Uint8> reserved;
  @ffi.Uint32()
  external int nth;
  @ffi.Array(16)
  external ffi.Array<ffi.Uint8> uuid;
  @ffi.Array(64)
  external ffi.Array<ffi.Uint8> name;
}

@ffi.Native<NativePadDevice Function(ffi.Uint32)>(
  symbol: 'prismarine_pad_device',
)
external NativePadDevice padDevice(int i);

@ffi.Native<NativePadReading Function(ffi.Uint64, ffi.Uint64, ffi.Uint32)>(
  symbol: 'prismarine_pad_read_chosen',
)
external NativePadReading padReadChosen(int uuidHi, int uuidLo, int nth);
