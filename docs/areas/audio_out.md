# prismarine_audio_out

The package plays audio on the desktop. It decodes MP3 and Ogg Vorbis files outside the Dart heap, keeps decoded files
in a cache that every isolate shares, streams long files and pushes PCM into the default output device. Its native
library is a Rust crate in `native/`, which the build hook builds through `prismarine_cargo`. The vendored C decoders
minimp3 and stb_vorbis are in `third_party/`, unmodified.

## Decoding

`decodeAudioFile` decodes a whole `.mp3` or `.ogg` file into a `MemoryPcmSource` and throws a `FormatException` for a
missing or broken file. `AsyncPcmSource` decodes a whole file on a native worker thread and reads silence until it is
ready. `StreamingPcmSource` decodes an Ogg Vorbis file as it plays. Opening it decodes the first half second, and a
feeder thread keeps decoded frames ahead of each reader. Frames that the feeder has not reached read as silence and are
counted.

The decoded bits are the same on macOS, Linux and Windows, on arm64 and x86-64. The C code compiles without fused
multiply-adds, and stb_vorbis takes `sin`, `cos`, `exp`, `log` and `pow` from the Rust `libm` crate in place of the
maths of the platform. The checksum test of the crate holds the bits of two synthetic files.

## The decoded-audio cache

`PcmCache` is one cache for the whole process, keyed by the path that you pass. One isolate asks for a file ahead of
its use with `PcmCache.want`, and another plays it with `CachedPcmSource.acquire`, which holds the entry while the
source lives. Decodes run on two threads below the priority of the frame. `PcmCache.sceneChanged` starts a new
generation. An entry that nobody holds is dropped two generations after it was last wanted, and the oldest entries
that nobody holds are dropped while the cache is over its budget. The default budget is 512 MB, and
`PcmCache.budgetFromEnvironment` reads another one from `PRISMARINE_PCM_BUDGET` in MB.

## Output

`PcmPushStream` opens the default output device through cpal, at 48 kHz stereo float32, and drains a ring of two
seconds in the callback of the device. Any isolate reaches a stream by its address. Its clock is the frames that the
device has taken. A paused stream takes nothing, a muted one plays silence and a ring that runs dry plays silence until
50 ms are queued again. The output fades in and out over 10 ms.

`RenderIsolate` runs an `IsolateRenderer` on its own isolate. You pass a function that makes the renderer there. With a
stream, the isolate keeps the ring filled a given lead ahead of the device, and pauses of the main isolate do not
starve it. Without one, the isolate renders the blocks that you ask for with `render`. Other messages that you send go
to the renderer.

## The native engine

The crate holds the native render of the audio engine of [prismarine_audio](audio.md) in `native/src/mix/`, a module
for each Dart file that it mirrors. `NativeAudioEngine.fromBlob` makes an engine from the bytes of `projectBlob`, with
the directory of the slot sounds and the `AudioRules`. In lockstep `render` renders on the calling thread and every
sample is decoded before its start is posted. In real time `startDevice` renders in the callback of the output device,
outside the Dart heap.

`NativeMixerPort` posts commands from any isolate. A poster builds the instance of a start with its strips, effects,
sound slots and nested pools and pushes the command into a lock-free queue. The render applies commands at their
frames and lets go of finished instances through the collector of `basedrop`. The render does not allocate or free,
and debug builds abort on an allocation inside it. A post does not allocate either. The limits are 256 instances, 64
mix states, 64 sounds per instance and 2 instances per nested instrument, and a full pool refuses with a problem.

The maths of the engine come from the `libm` crate in `mix/dmath.rs`, mirrored bit for bit by `libm.dart` of
`prismarine_math`, and the two change together. The render gives the same bits as the Dart render on macOS, Linux and
Windows, arm64 and x86-64. The `parity` example replays a session that `package:prismarine_audio/testing.dart` wrote
and compares the bits.

| Variable | Effect |
|---|---|
| `PRISMARINE_STREAM_HOLD` | `off` reads silence until the stream feeder reaches a start in place of holding the start. |
| `PRISMARINE_AUDIO_TAP` | A file that gets every sample of the device as raw float32 stereo at 48 kHz. |
| `PRISMARINE_MIX_DEBUG` | Set, the reader of the model logs its counts. |

## Native code of an app

An app whose own Rust crate uses the cache, streams or device of `native/` needs both in one library. Otherwise each
library would have its own cache. The crate depends on the crate in `native/`, and the root pubspec of the app sets
two user defines.

```yaml
hooks:
  user_defines:
    prismarine_audio_out:
      crate: native/mixer
      library: mixer
```

The hook then builds that crate in place of `native/`. The library exports the C functions of both crates, and the
bindings of the app use the asset `package:prismarine_audio_out/src/native.dart`.

| Variable | Effect |
|---|---|
| `PRISMARINE_PCM_BUDGET` | The budget of the cache in MB, read by `PcmCache.budgetFromEnvironment`. |
| `PRISMARINE_FEEDER_QOS` | `off` keeps the stream feeder at the priority it was made with, for A/B runs. |

Each variable also reads its `MCSM_` form when the `PRISMARINE_` form is not set.

## Checks

- `dart test` in `packages/prismarine_audio_out` decodes the synthetic files and runs the cache, a stream and a
  render isolate.
- `cargo test` in `packages/prismarine_audio_out/native` checks the decoded bits, the cache, the ring, the thread roles
  of each OS and the DSPs of the engine.
- `cargo run --release --example parity -- <dir>` replays a parity session of the engine.
- `cargo +nightly miri test` in the same directory runs the unit tests that call no C.
- `cargo clippy --all-targets` denies an undocumented `unsafe` block and the maths of the platform.
