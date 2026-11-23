# prismarine_audio_out

prismarine_audio_out plays audio on the desktop. It decodes MP3 and Ogg Vorbis files outside the Dart heap, keeps
decoded files in a cache that every isolate shares, streams long files and pushes PCM into the default output device.
Its native library is a Rust crate in `native/`, which the build hook builds through
[prismarine_cargo](../prismarine_cargo/README.md). The details are on [the area page](../../docs/areas/audio_out.md).

## Usage

`decodeAudioFile` decodes a whole `.mp3` or `.ogg` file into a `MemoryPcmSource` of
[prismarine_audio](../prismarine_audio/README.md). `AsyncPcmSource` decodes on a native thread and reads silence until
it is ready. `StreamingPcmSource` decodes an Ogg Vorbis file while it plays.

`PcmCache` is one cache of decoded files for the whole process. One isolate asks for a file ahead of its use with
`PcmCache.want`. Another isolate plays it through `CachedPcmSource.acquire`, which holds the entry for as long as the
source exists. `PcmCache.sceneChanged` lets the cache drop the entries that nobody wanted since the scene before.

`PcmPushStream.start` opens the default output device at 48 kHz stereo and throws a `StateError` on a machine without
one, such as a container. `RenderIsolate.spawn` runs your `IsolateRenderer` on an isolate of its own, which keeps the
stream filled ahead of the device. A pause of the main isolate then does not starve the device.

## Example

The example plays a 48 kHz stereo file from the cache through a render isolate. It is
[`example/example.dart`](example/example.dart):

```dart
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:prismarine_audio_out/prismarine_audio_out.dart';

/// Plays one 48 kHz stereo file from the shared cache, then silence.
class FilePlayer implements IsolateRenderer {
  FilePlayer(String path) : _sound = CachedPcmSource.acquire(path);

  final CachedPcmSource _sound;
  var _at = 0;

  @override
  Float32List render(int frames) {
    final out = Float32List(frames * 2);
    if (pcmReady(_sound)) _at += _sound.read(out, _at, frames);
    return out;
  }

  @override
  void receive(Object? message) {}

  @override
  void stop() {}
}

/// Plays the 48 kHz stereo `.ogg` or `.mp3` file given as the argument.
Future<void> main(List<String> args) async {
  final path = args.single;
  PcmCache.want(path);
  final length = decodeAudioFile(path).frames / 48000;

  final PcmPushStream device;
  try {
    device = PcmPushStream.start();
  } on StateError catch (e) {
    print('$e');
    return;
  }
  final audio = await RenderIsolate.spawn(
    (host) => FilePlayer(path),
    stream: device.address,
    lead: 0.1,
  );
  await Future<void>.delayed(Duration(milliseconds: (length * 1000).ceil()));
  print('played ${device.consumed.toStringAsFixed(2)} s of $path');
  await audio.dispose();
  device.dispose();
}
```

Run it with a file, such as the test file of the crate:

    dart run example/example.dart native/tests/data/synthetic.ogg

## Platforms

The package runs on macOS, Linux and Windows. The decoded bits are the same on each OS and CPU. The output uses Core
Audio on macOS, ALSA on Linux and WASAPI on Windows. A Linux build needs the ALSA headers, the package `libasound2-dev`
on Ubuntu.
