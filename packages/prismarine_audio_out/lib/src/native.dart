// The C functions of the native library (native/) for the decoders, the
// decoded-audio cache, streams and the output ring.
@ffi.DefaultAsset('package:prismarine_audio_out/src/native.dart')
library;

import 'dart:ffi' as ffi;

typedef _Decode =
    ffi.Int64 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int64,
      ffi.Pointer<ffi.Pointer<ffi.Float>>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
    );

@ffi.Native<_Decode>(symbol: 'prismarine_mp3_decode')
external int mp3Decode(
  ffi.Pointer<ffi.Uint8> data,
  int len,
  ffi.Pointer<ffi.Pointer<ffi.Float>> out,
  ffi.Pointer<ffi.Int32> channels,
  ffi.Pointer<ffi.Int32> rate,
);

@ffi.Native<_Decode>(symbol: 'prismarine_ogg_decode')
external int oggDecode(
  ffi.Pointer<ffi.Uint8> data,
  int len,
  ffi.Pointer<ffi.Pointer<ffi.Float>> out,
  ffi.Pointer<ffi.Int32> channels,
  ffi.Pointer<ffi.Int32> rate,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'prismarine_audio_free',
)
external void audioFree(ffi.Pointer<ffi.Void> p);

// Streamed Ogg Vorbis (native/src/decode/stream.rs).
final class NativeStream extends ffi.Opaque {}

@ffi.Native<
  ffi.Pointer<NativeStream> Function(ffi.Pointer<ffi.Char>, ffi.Double)
>(symbol: 'prismarine_stream_open')
external ffi.Pointer<NativeStream> streamOpen(
  ffi.Pointer<ffi.Char> path,
  double headSeconds,
);

@ffi.Native<
  ffi.Void Function(
    ffi.Pointer<NativeStream>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int64>,
  )
>(symbol: 'prismarine_stream_info')
external void streamInfo(
  ffi.Pointer<NativeStream> s,
  ffi.Pointer<ffi.Int32> channels,
  ffi.Pointer<ffi.Int32> rate,
  ffi.Pointer<ffi.Int64> frames,
);

@ffi.Native<
  ffi.Int64 Function(
    ffi.Pointer<NativeStream>,
    ffi.Pointer<ffi.Float>,
    ffi.Int64,
    ffi.Int64,
  )
>(symbol: 'prismarine_stream_read', isLeaf: true)
external int streamRead(
  ffi.Pointer<NativeStream> s,
  ffi.Pointer<ffi.Float> out,
  int frame,
  int count,
);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<NativeStream>)>(
  symbol: 'prismarine_stream_take_missing',
  isLeaf: true,
)
external int streamTakeMissing(ffi.Pointer<NativeStream> s);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeStream>)>(
  symbol: 'prismarine_stream_close',
)
external void streamClose(ffi.Pointer<NativeStream> s);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<NativeStream>)>(
  symbol: 'prismarine_stream_ready',
  isLeaf: true,
)
external int streamReady(ffi.Pointer<NativeStream> s);

// Background whole-file decodes (native/src/decode/jobs.rs).
final class NativeJob extends ffi.Opaque {}

@ffi.Native<ffi.Pointer<NativeJob> Function(ffi.Pointer<ffi.Char>)>(
  symbol: 'prismarine_decode_async',
)
external ffi.Pointer<NativeJob> decodeAsync(ffi.Pointer<ffi.Char> path);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<NativeJob>)>(
  symbol: 'prismarine_job_state',
  isLeaf: true,
)
external int jobState(ffi.Pointer<NativeJob> j);

@ffi.Native<
  ffi.Pointer<ffi.Float> Function(
    ffi.Pointer<NativeJob>,
    ffi.Pointer<ffi.Int64>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
  )
>(symbol: 'prismarine_job_result')
external ffi.Pointer<ffi.Float> jobResult(
  ffi.Pointer<NativeJob> j,
  ffi.Pointer<ffi.Int64> frames,
  ffi.Pointer<ffi.Int32> channels,
  ffi.Pointer<ffi.Int32> rate,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeJob>)>(
  symbol: 'prismarine_job_release',
)
external void jobRelease(ffi.Pointer<NativeJob> j);

// The decoded-audio cache (native/src/decode/cache.rs).
final class NativePcm extends ffi.Opaque {}

@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Char>)>(
  symbol: 'prismarine_pcm_want',
)
external int pcmWant(ffi.Pointer<ffi.Char> path);

@ffi.Native<ffi.Pointer<NativePcm> Function(ffi.Pointer<ffi.Char>)>(
  symbol: 'prismarine_pcm_acquire',
)
external ffi.Pointer<NativePcm> pcmAcquire(ffi.Pointer<ffi.Char> path);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<NativePcm>)>(
  symbol: 'prismarine_pcm_state',
  isLeaf: true,
)
external int pcmState(ffi.Pointer<NativePcm> e);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<NativePcm>)>(
  symbol: 'prismarine_pcm_wait',
)
external int pcmWait(ffi.Pointer<NativePcm> e);

@ffi.Native<
  ffi.Pointer<ffi.Float> Function(
    ffi.Pointer<NativePcm>,
    ffi.Pointer<ffi.Int64>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
  )
>(symbol: 'prismarine_pcm_data')
external ffi.Pointer<ffi.Float> pcmData(
  ffi.Pointer<NativePcm> e,
  ffi.Pointer<ffi.Int64> frames,
  ffi.Pointer<ffi.Int32> channels,
  ffi.Pointer<ffi.Int32> rate,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(
  symbol: 'prismarine_pcm_release',
)
external void pcmRelease(ffi.Pointer<ffi.Void> e);

/// The release as a finalizer callback (a source's reference).
final pcmReleasePtr =
    ffi.Native.addressOf<
      ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>
    >(pcmRelease);

@ffi.Native<ffi.Void Function()>(symbol: 'prismarine_pcm_scene_changed')
external void pcmSceneChanged();

@ffi.Native<ffi.Void Function(ffi.Int64)>(symbol: 'prismarine_pcm_set_budget')
external void pcmSetBudget(int bytes);

@ffi.Native<ffi.Void Function()>(symbol: 'prismarine_pcm_clear')
external void pcmClear();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Int64>)>(
  symbol: 'prismarine_pcm_stats',
)
external void pcmStats(ffi.Pointer<ffi.Int64> out);

/// The output ring into the device (native/src/push.rs).
final class NativePushStream extends ffi.Opaque {}

@ffi.Native<ffi.Pointer<NativePushStream> Function(ffi.Pointer<ffi.Int32>)>(
  symbol: 'prismarine_push_start',
)
external ffi.Pointer<NativePushStream> pushStart(ffi.Pointer<ffi.Int32> err);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativePushStream>)>(
  symbol: 'prismarine_push_destroy',
)
external void pushDestroy(ffi.Pointer<NativePushStream> s);

@ffi.Native<
  ffi.Int64 Function(
    ffi.Pointer<NativePushStream>,
    ffi.Pointer<ffi.Float>,
    ffi.Int64,
  )
>(symbol: 'prismarine_push_pcm', isLeaf: true)
external int pushPcm(
  ffi.Pointer<NativePushStream> s,
  ffi.Pointer<ffi.Float> pcm,
  int frames,
);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<NativePushStream>)>(
  symbol: 'prismarine_push_consumed',
  isLeaf: true,
)
external int pushConsumed(ffi.Pointer<NativePushStream> s);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativePushStream>, ffi.Int32)>(
  symbol: 'prismarine_push_set_paused',
  isLeaf: true,
)
external void pushSetPaused(ffi.Pointer<NativePushStream> s, int paused);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativePushStream>, ffi.Int32)>(
  symbol: 'prismarine_push_set_muted',
  isLeaf: true,
)
external void pushSetMuted(ffi.Pointer<NativePushStream> s, int muted);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<NativePushStream>)>(
  symbol: 'prismarine_push_underruns',
  isLeaf: true,
)
external int pushUnderruns(ffi.Pointer<NativePushStream> s);
