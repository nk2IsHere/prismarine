# prismarine_audio

The package holds the interfaces of decoded audio. It has no native code and no Flutter, and you can use it from any
isolate or tool.

`PcmSource` is decoded audio as interleaved float32 frames, with its channel count, sample rate and length. A player
reads frames from it at any position with `read`. `MemoryPcmSource` holds a whole decoded file in memory. A
`LoadingPcmSource` is a source whose data is still loading on another thread, and `pcmReady` tells whether a source has
its data. The player decides what a sound on a loading source does, such as starting late or holding its timeline.

`WavWriter` streams 48 kHz stereo float32 frames into a WAV file and writes the sizes into its header on `close`.

## Checks

Run `dart test` in `packages/prismarine_audio`.
