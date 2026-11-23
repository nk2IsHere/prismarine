/// The native mixer's entry points. The library is prismarine_audio_out's
/// asset, which its build hook builds from native/mixer through the hooks
/// section of the pubspecs.
@ffi.DefaultAsset('package:prismarine_audio_out/src/native.dart')
library;

import 'dart:ffi' as ffi;

final class NativeMixer extends ffi.Opaque {}

@ffi.Native<
  ffi.Pointer<NativeMixer> Function(
    ffi.Pointer<ffi.Uint8>,
    ffi.Int64,
    ffi.Int64,
    ffi.Int32,
    ffi.Int64,
    ffi.Double,
    ffi.Int32,
  )
>(symbol: 'prismarine_mix_create')
external ffi.Pointer<NativeMixer> mixCreate(
  ffi.Pointer<ffi.Uint8> blob,
  int len,
  int seed,
  int streaming,
  int reportLag,
  double lateStartMinimum,
  int wholeMsLengths,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeMixer>)>(
  symbol: 'prismarine_mix_destroy',
)
external void mixDestroy(ffi.Pointer<NativeMixer> e);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<NativeMixer>,
    ffi.Int32,
    ffi.Int32,
    ffi.Int64,
    ffi.Double,
    ffi.Double,
    ffi.Int32,
    ffi.Double,
    ffi.Int32,
    ffi.Double,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
>(symbol: 'prismarine_mix_post')
external int mixPost(
  ffi.Pointer<NativeMixer> e,
  int op,
  int id,
  int at,
  double value,
  double seek,
  int hasLate,
  double late,
  int flag,
  double keepTail,
  ffi.Pointer<ffi.Char> name,
  ffi.Pointer<ffi.Char> sound,
  ffi.Pointer<ffi.Char> via,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeMixer>)>(
  symbol: 'prismarine_mix_scene',
)
external void mixScene(ffi.Pointer<NativeMixer> e);

@ffi.Native<
  ffi.Void Function(ffi.Pointer<NativeMixer>, ffi.Pointer<ffi.Float>, ffi.Int64)
>(symbol: 'prismarine_mix_render')
external void mixRender(
  ffi.Pointer<NativeMixer> e,
  ffi.Pointer<ffi.Float> out,
  int frames,
);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<NativeMixer>)>(
  symbol: 'prismarine_mix_position',
  isLeaf: true,
)
external int mixPosition(ffi.Pointer<NativeMixer> e);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<NativeMixer>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
  )
>(symbol: 'prismarine_mix_problem')
external int mixProblem(
  ffi.Pointer<NativeMixer> e,
  ffi.Pointer<ffi.Uint8> out,
  int cap,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<NativeMixer>)>(
  symbol: 'prismarine_mix_start',
)
external int mixStart(ffi.Pointer<NativeMixer> e);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<NativeMixer>)>(
  symbol: 'prismarine_mix_consumed',
  isLeaf: true,
)
external int mixConsumed(ffi.Pointer<NativeMixer> e);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeMixer>, ffi.Int32)>(
  symbol: 'prismarine_mix_set_paused',
  isLeaf: true,
)
external void mixSetPaused(ffi.Pointer<NativeMixer> e, int paused);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeMixer>, ffi.Int32)>(
  symbol: 'prismarine_mix_set_muted',
  isLeaf: true,
)
external void mixSetMuted(ffi.Pointer<NativeMixer> e, int muted);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<NativeMixer>,
    ffi.Pointer<ffi.Int64>,
    ffi.Int32,
  )
>(symbol: 'prismarine_mix_stats')
external int mixStats(
  ffi.Pointer<NativeMixer> e,
  ffi.Pointer<ffi.Int64> out,
  int max,
);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<NativeMixer>)>(
  symbol: 'prismarine_mix_missing',
)
external int mixMissing(ffi.Pointer<NativeMixer> e);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<NativeMixer>, ffi.Int64)>(
  symbol: 'prismarine_mix_set_position',
)
external int mixSetPosition(ffi.Pointer<NativeMixer> e, int frames);
