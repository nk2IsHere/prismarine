# The audio engine

prismarine gets its own audio engine: events, buses with effect chains, sends and sidechains, voices that play
decoded samples, positional panning and mix states. A game describes its sound in an audio project and drives it with
commands at exact frames. The engine renders in Dart and in a native mirror that gives the same bits. The native
render runs in the callback of the output device.

The engine starts from the audio of mcsm, which reproduces FMOD Studio 1.06 and 1.09 bit for bit. mcsm keeps its FMOD
bank reader, its Telltale sound rules and its tests against FMOD. They become adapters over the engine. The render code
moves to prismarine and loses every FMOD and game word on the way. mcsm's outputs stay byte-identical.

## Goals

- A game uses the engine without any knowledge of FMOD or of a game. It builds a project in code, makes an engine and
  sends commands. A JSON form of the project comes later, as a goal.
- One model and one render for every user. The behaviours that differ between FMOD 1.06 and 1.09 become data of the
  model, set by mcsm's adapter, or settings of the engine with neutral names.
- The Dart render and the native render give identical bits on macOS, Linux and Windows, arm64 and x86-64. A parity
  tool proves it for any project and command script.
- Code that a frame runs does not allocate. The native render allocates and frees nothing, as today. The Dart render,
  the command post and the lockstep step are roots of prismarine's alloc lint.
- mcsm stays bit-exact: its parity test, the audio of its D1 capture, the parity run of its first episode with its
  60,873,600 samples and its corpus do not change.

## Not in scope

- New behaviour. The engine plays what mcsm plays today. New effects, an editor for projects and object-based output
  can come later.
- Snapshots of the render state for replay. The engine holds no state that a replay snapshot saves. A game that
  restores a snapshot starts its sounds again at their positions with ordinary commands.
- The Telltale sound rules, the bank load order of the exe, the session log of mcsm and its tools against FMOD. They
  stay in mcsm.

## Packages

| Package | Contents after the change |
|---|---|
| `prismarine_audio` | `PcmSource`, `WavWriter`, the project model with its binary codec, the Dart engine with its commands, `LockstepAudio` and `AudioClock`. The parity writer is in a separate library, `package:prismarine_audio/testing.dart`, which a game does not import. |
| `prismarine_audio_out` | The output device, the push ring, the decoders and the cache as today, plus the native engine in the crate, `NativeAudioEngine` and `NativeMixerPort`. The parity replay is an example of the crate and not part of its library. |

## Two renders

The engine has a Dart render and a native render and both stay. They have different jobs. The native render plays in
real time. It runs in the callback of the output device, outside the Dart heap and a pause of an isolate or a
collection of its heap does not starve it. The Dart render is for offline and lockstep work. It renders on any isolate
and on any platform without the native library, for captures that step with the game, for tools that render one event
to a file and for tests. A capture can use either render and both give the same bits. The Dart render is also the
reference that the native one is checked against and a change to one is made in the other in the same float order.

## The native library

The native engine joins the crate of `prismarine_audio_out`. The decoded-audio cache and the engine must be in one
library. A separate crate would need the user defines that mcsm uses today and every app would have to set them.
`mcsm_audio_out` loses its crate and its user defines.

`dmath.rs` moves into the crate beside `libm.dart` of `prismarine_math`. The rule that the mixer maths change in both
at once becomes a rule of prismarine alone. The clippy list that forbids the maths of the platform and fused
multiply-adds already holds for the crate.

## The project model

A project is the static description of the sound of a game. The engine reads it once. The Dart classes are immutable
after load. `projectBlob` writes the binary form that the native engine reads. The events and mix states are maps by
path and a game that merges several sources keeps the first entry of a path.

| Part | Contents |
|---|---|
| `MixerDef` | The buses of the mixer, each a `StripDef`, with one master bus. |
| `EventDef` | Its name, its kind (`event` or `mixState`), a master track, tracks, returns and an optional output strip, parameters, a timeline, a polyphony limit, `oneShot` and, for a mix state, its `MixStateDef`. |
| `StripDef` | An id, an optional name, the strip it feeds and the mixer bus that an event's output strip feeds, a volume in dB, a pitch, a channel layout, effects and automated properties. |
| `EffectDef` | One stage of a strip: a `DspEffect` with its kind and parameters, a `SendEffect` into a return bus at a level, or a `SidechainTap` into compressors. Each has an id, a bypass flag and a pre-fader flag. |
| `PropertyDef` | Automation curves and modulators on one property of a strip, an effect or an instrument, with a mapping from UI units. |
| `InstrumentDef` | A `sample`, `playlist`, `scatterer`, `slot`, `event` or `mixState` instrument with its volume, pitch, loop count, trigger chance and delay, start offset, polyphony and spawn settings. |
| `Placement` and `SheetPlacement` | An instrument on the timeline in frames, with `timelocked` and `fill`, or on a parameter sheet in parameter units. |
| `ParameterDef` | A game parameter, a distance or a cone angle, with its range and default. |
| `TimelineDef` | Placements, tempo markers, loop regions and transitions with conditions and quantization. |
| `MixStateDef` | A priority, an intensity, entries that pull properties of the mixer toward values and their automation. |
| `WaveformDef` | A key, a file path, `streamed`, the frame count, the rate and the channel count. |

The engine uses enums where FMOD uses numbers: `ChannelLayout`, `EffectKind`, `PolyphonyMode` (`failNew`,
`stealOldest`), `PlaylistMode` (`sequential`, `shuffle`), `ParameterKind` (`game`, `distance`, `cone`),
`ModulatorKind` (`random`, `ahdsr`) and `Rolloff`. Properties keep numbers, with constants for the volume, the pitch,
the fade gain, the intensity, the 3D offsets, the start offset and the parameters of an effect from 1000 on. Mix state
entries refer to them.

Each `EffectKind` has a fixed list of parameters with their defaults and their units. The page of the package has the
table. The order is the order of the render code today: the lowpass has the cutoff and the resonance, the pan has 24
parameters from its mode to its surround target. A `DspEffect` holds a value, an on or off switch, or nothing for each
parameter. A parameter with nothing keeps its default and has no stored value for mix states.

### Behaviour that is data

FMOD 1.06 and 1.09 differ in a few places. Each one becomes a field of the model and the adapter of mcsm sets it from
the version of the bank. A project built in code gives the field or takes its default.

| Field | Meaning | 1.06 | 1.09 |
|---|---|---|---|
| `Placement.fill` | A timelocked sample shorter than its box repeats until the box ends. | every box | a looping sample only |
| `EventDef.oneShot` | The event ends on its own. The default is true without a loop region and without a sample that loops forever outside a timelocked box. | timelocked boxes count | timelocked boxes do not count |
| `DspEffect.passAtTop` | A lowpass at a cutoff of 22000 Hz or more and a resonance of 1 or less passes its input unchanged. | true | false |

The strip formats of an event, the 5.1 strips and the fold of a 5.1 master to stereo follow from the layouts in the
model and need no flag.

## Commands

The engine takes `AudioCommand`s, each with the id of an instance that the game picks.

| Command | Effect |
|---|---|
| `StartEvent(id, event, seek:, sound:, late:)` | Starts an event `seek` seconds into its timeline. `sound` is the key of the sample that its slot instruments play. `late` makes the seek the wanted position of a start that comes late. |
| `SetParameter(id, name, value)` | Sets a game parameter, clamped to its range. |
| `SetVolume(id, volume, keepTail:)` | Sets the volume of the instance, ramped over one block. A volume set before the first block is the start volume. |
| `SetPaused(id, paused)` | A paused instance is silent and does not advance. |
| `SetSpatial(id, azimuth, distance, cone)` | The position of the instance relative to the listener. |
| `StopEvent(id, mode:, keepTail:, viaParameter:)` | Stops with a fade, at once, or by setting a parameter to 1 when the event has it. |
| `StartMixState(id, name)`, `SetMixStateParameter`, `StopMixState(id)` | The same for mix states. |

`keepTail` is a time in seconds. A one-shot event with less time left than `keepTail` ignores a stop and a zero volume
after its first block. The time left counts from the reported position, which trails the render by
`AudioRules.reportLag` frames.

`late` holds a tolerance in seconds. The engine starts at the wanted position only when the position is past the
tolerance and past `AudioRules.lateStartMinimum` and the event or its sound is longer than the tolerance. A start
whose wanted position is past the end of the event or of its sound does not play. With `AudioRules.wholeMsLengths`
the length of a sound is rounded down to whole milliseconds.

`AudioRules` holds these values for the whole engine. The defaults are zero and false. mcsm sets a lag of 1024 frames,
a minimum of 0.1 s and whole milliseconds and the command forms of its sound rules.

The commands are plain values that any isolate can send. `AudioRenderer` is the interface of a render with a frame
position, `schedule`, `apply` and `render`. `AudioEngine` implements it in Dart and `NativeAudioEngine` implements it
over the native engine. `LockstepAudio` advances a renderer to a time and applies commands at their frames.
A game plays the native engine in real time with `NativeAudioEngine.startDevice`, or a Dart engine on a
`RenderIsolate` into a `PcmPushStream`. mcsm's `AudioOutput`, which adds the command latency of FMOD's ring, stays in
mcsm.

## The native engine

The crate keeps the layout of mcsm's mixer crate with prismarine names. The render runs in the callback of the
device at 48 kHz stereo, in blocks of 1024 frames. Posters on any isolate build the instance of a start, with its
strips, effects, sound slots and nested pools and push the command into a lock-free queue. The render applies
commands at their frames, renders and lets go of finished instances through `basedrop`'s collector. Debug builds abort
on an allocation inside the render.

The C functions have the form `prismarine_mix_*`. `projectBlob` and `NativeAudioEngine` replace the model blob and the
engine class of mcsm. The poster resolves the sound key of a start against a sound directory that the game passes.

## Bits and checks

The move changes no arithmetic. Every function keeps its float order and the render code changes only where the
model gives typed values in place of FMOD records. The checks:

- The parity writer of `package:prismarine_audio/testing.dart` renders a project and a command script in Dart and
  writes the blob, the script and the render. The `parity` example of the crate replays them natively and compares the bits.
- prismarine has a synthetic project with generated samples, which covers every effect kind, each instrument kind,
  5.1 strips, mix states and sidechains. Its render checksum is stored and holds on every platform.
- mcsm's `native_parity.dart` builds the project from a slice through the adapter and calls the parity writer. The
  Dart checksums of mcsm's parity sets, four sessions over episodes of its first season, one scene of its second
  and its synthetic slice, must equal the ones from before the change. The native replay must equal them.
- The coordinator runs D1 and the corpus before landing.

## mcsm after the change

- `mcsm_audio` keeps the bridge, the bank loader with the load order of the exe, the adapter from `events.json` to the
  project, the low-level voice event, the session log, the prefetch, the tools and the tests against FMOD.
- The adapter maps FMOD's DSP types, parameter types, property indices, layouts, polyphony modes and playlist modes to
  the enums of the model and sets the behaviour fields from the bank's format version.
- The bridge sends prismarine's commands. Its snapshot codec keeps its tags and bytes: each tag maps to the command
  form that mcsm's sound rules use, `StopChannel` to `StopEvent` with a fade through `Stop Trigger` and a tail of
  0.5 s, for example. Snapshot bytes and route hashes do not change.
- The session log keeps its JSON lines.

## Replay

prismarine_audio exports no snapshot codecs and does not import `prismarine_replay`. `prismarine_replay` does not
import `prismarine_audio`. mcsm passes its bridge to the tail section of a replay snapshot, with its codecs in the
game's registry, as today. This boundary is agreed with the replay design.

## Allocation

The roots of prismarine's alloc lint gain `AudioEngine.render`, `apply` and `schedule`, `LockstepAudio.advanceTo` and
`NativeMixerPort.post`. The post allocates nothing. The Dart render starts with 547 counted places, which form the
baseline and only fall. Its rewrite keeps its buffers per strip and per instance, sums the outputs of instances into
kept buffers by bus and keeps its queue sorted in place. Allocations that remain at a start of an instance, such as its
strips and effects, carry `// alloc: <reason>`. The rewrite is a step of its own with its own parity runs.

## Steps

1. In mcsm: the typed model, the adapter and the generic commands in `mcsm_audio` and the same model in the crate,
   with the parity checksums unchanged. This cut can land on its own.
2. The move: the Dart engine to `prismarine_audio`, the crate's engine to `prismarine_audio_out`, with prismarine
   names and comments. mcsm imports them and deletes its copies and its crate.
3. The alloc roots with the post at zero and the Dart render's count as the baseline.
4. The synthetic project with its stored checksum and its native parity, the page of the package, its README and its
   example. mcsm's audio page links to it.
5. The Dart render without allocation in steady frames, with its own parity runs.

## Risks

- **Summing order.** The engine sums instances into buses in the order in which they first reach a bus in a block.
  Kept buffers must keep that order, or the bits change.
- **Stored values.** A parameter with a switch value has no stored value for mix states today and a parameter with
  nothing keeps its default. The model keeps both cases apart.
- **Snapshot bytes.** The bridge's codec must write the same bytes for the same commands.
- **Two repositories.** The move lands in prismarine first. mcsm's pin bump deletes its crate and changes its pubspecs
  in the same landing.
