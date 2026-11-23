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
