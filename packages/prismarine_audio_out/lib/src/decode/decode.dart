import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:prismarine_audio/prismarine_audio.dart';

import '../native.dart';

/// Decodes a slice audio file (`.mp3` voice, `.ogg` bank sample) into memory.
/// A missing or undecodable file is a [FormatException] naming it.
MemoryPcmSource decodeAudioFile(String path) {
  final f = File(path);
  if (!f.existsSync()) throw FormatException('$path: missing audio file');
  final bytes = f.readAsBytesSync();
  final mp3 = path.toLowerCase().endsWith('.mp3');
  return using((arena) {
    final data = arena<ffi.Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final out = arena<ffi.Pointer<ffi.Float>>();
    final channels = arena<ffi.Int32>(), rate = arena<ffi.Int32>();
    final frames = (mp3 ? mp3Decode : oggDecode)(
      data,
      bytes.length,
      out,
      channels,
      rate,
    );
    if (frames < 0) throw FormatException('$path: cannot decode');
    try {
      final n = frames * channels.value;
      return MemoryPcmSource(
        Float32List.fromList(out.value.asTypedList(n)),
        channels: channels.value,
        sampleRate: rate.value,
      );
    } finally {
      audioFree(out.value.cast());
    }
  });
}
