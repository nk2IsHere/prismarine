# prismarine_audio

The package is an audio engine of events, buses with effect chains, voices and mix states, rendered in Dart. Its
native render in [prismarine_audio_out](audio_out.md) gives the same bits. The package also holds the interfaces of
decoded audio and a WAV writer. It has no native code and no Flutter, and you can use it from any isolate or tool.

## The project

A project describes the sound of a game, and you build it in code from the classes of `model.dart`. An `EventDef` has
a master track, tracks and returns, each a `StripDef` with effects, and an optional input bus that feeds a bus of the
mixer by path. Instruments play on a `TimelineDef` in 48 kHz frames or on the sheets of a `ParameterDef`. A
`sample` instrument plays a waveform, a `playlist` picks one of its entries, a `scatterer` spawns entries at random
intervals and positions, a `slot` plays the sound that a start passes, and an `event` instrument plays a nested event
or applies a mix state. Automation curves and modulators move the properties of strips, effects and instruments.

The `MixerDef` holds the buses of the mixer with one master bus and the path of each bus. A mix state is an
`EventDef` of kind `mixState` whose `MixStateDef` pulls properties of the mixer toward values by its intensity.
Volumes and the dB parameters of effects blend in linear gain, and a property that no mix state touches returns to its
stored value.

Three fields set behaviour that differs between sound tools. `Placement.fill` repeats a timelocked waveform until its
box ends. `EventDef.oneShot` says that an event ends on its own and decides the tail rules of `keepTail`.
`DspEffect.passAtTop` makes a lowpass at its top cutoff pass its input unchanged.

## Effects

A `DspEffect` has one of these kinds, with its parameters by index. A parameter without a value keeps its default.

| Kind | Parameters | Defaults |
|---|---|---|
| `lowpass` | cutoff Hz, resonance | 5000, 1 |
| `highpass` | cutoff Hz, resonance | 5000, 1 |
| `echo` | delay ms, feedback %, dry dB, wet dB | 500, 50, 0, 0 |
| `flange` | mix %, depth, rate Hz | 50, 1, 0.1 |
| `distortion` | level | 0.5 |
| `parametricEq` | centre Hz, bandwidth, gain dB | 8000, 1, 0 |
| `limiter` | release ms, ceiling dB, maximizer dB, linked | 10, 0, 0, 0 |
| `compressor` | threshold dB, ratio, attack ms, release ms, make-up dB, sidechain, linked | 0, 2.5, 20, 100, 0, 0, 1 |
| `reverb` | decay ms, early delay ms, late delay ms, HF reference Hz, HF ratio %, diffusion %, density %, low shelf Hz, low shelf dB, high cut Hz, early and late mix %, wet dB, dry dB | 1500, 20, 40, 5000, 50, 100, 100, 250, 0, 20000, 50, −6, 0 |
| `tremolo` | rate Hz, depth, shape, skew, duty, square, phase, spread | 5, 1, 0, 0, 0.5, 0, 0, 0 |
| `pan` | mode, 2D position, then the surround and 3D parameters up to the target speaker mode at 20 | see `Pan` |
| `threeBandEq` | low, mid and high gain dB, low and high crossover Hz, slope | 0, 0, 0, 400, 4000, 1 |
| `chorus` | mix %, rate Hz, depth | 100, 0.8, 3 |
| `multibandEq` | type, frequency Hz, Q and gain dB of bands A to E | see `MultibandEq` |
| `channelMix` | output grouping, gain dB of channels 0 to 31 | 0 and 0 dB |
| `objectPan` | the object panner, whose output is silence | see `ObjectPan` |

A compressor with `sidechainInput` takes its key from the `SidechainTap`s that name it. A `SendEffect` sends the
signal of its strip into a return bus at its level.

## Commands and renders

A game drives the engine with `AudioCommand`s, each with the id of an instance that the game picks. `StartEvent`
starts an event, with the key of a sound for its slot instruments. `SetParameter`, `SetVolume`, `SetPaused` and
`SetSpatial` change an instance, and `StopEvent` stops it with a fade, at once or through a parameter. `StartMixState`,
`SetMixStateParameter` and `StopMixState` do the same for mix states. Commands are plain values that you can send to
another isolate.

`AudioRules` holds the settings that hold for every command. `reportLag` makes the reported position of an instance
trail its render, `lateStartMinimum` and `wholeMsLengths` shape a late start. The defaults are 0 and false.

`AudioEngine` is the Dart render. `schedule` applies a command at a frame, `apply` before the next frame, and `render`
returns the next stereo frames of the master bus. The render is deterministic. Its maths come from `prismarine_math`,
and it gives the same bits on every platform. `LockstepAudio` advances a renderer to the time of a game and applies
commands at their frames, for captures. The native render is for real-time play, and `projectBlob` writes the project
in the form that it reads.

| Rule | Effect |
|---|---|
| Dart and native renders | A change to one is made in the other, in the same float order. |
| Maths | The native `dmath.rs` and `libm.dart` of `prismarine_math` change together. |
| Allocation | The Dart render is a root of the alloc lint. Its count only falls. |

## Decoded audio

`PcmSource` is decoded audio as interleaved float32 frames, with its channel count, sample rate and length. A player
reads frames from it at any position with `read`. `MemoryPcmSource` holds a whole decoded file in memory. A
`LoadingPcmSource` is a source whose data is still loading on another thread, and `pcmReady` tells whether a source has
its data. `WavWriter` streams 48 kHz stereo float32 frames into a WAV file and writes the sizes into its header on
`close`.

## Checks

- `dart test` in `packages/prismarine_audio` runs the DSPs, the panners, the source reader and the synthetic project,
  whose render checksum is stored.
- `dart run tool/synthetic_parity.dart <dir>` writes the parity session of the synthetic project. The `parity` example
  of prismarine_audio_out replays it on the native engine and compares the bits. The tests workflow runs both.
- `package:prismarine_audio/testing.dart` writes a parity session for any project and script.
