import 'dart:io';
import 'dart:typed_data';

/// Streams 48 kHz stereo float32 frames into a WAV file. [close] writes the
/// sizes into the header.
class WavWriter {
  WavWriter(String path, {this.rate = 48000})
    : _f = File(path).openSync(mode: FileMode.write) {
    _f.writeFromSync(Uint8List(44));
  }

  final int rate;
  final RandomAccessFile _f;
  int frames = 0;

  /// Appends interleaved stereo frames.
  void add(Float32List stereo) {
    _f.writeFromSync(
      stereo.buffer.asUint8List(stereo.offsetInBytes, stereo.lengthInBytes),
    );
    frames += stereo.length ~/ 2;
  }

  void close() {
    final data = frames * 8;
    final h = ByteData(44)
      ..setUint32(0, 0x46464952, Endian.little) // RIFF
      ..setUint32(4, 36 + data, Endian.little)
      ..setUint32(8, 0x45564157, Endian.little) // WAVE
      ..setUint32(12, 0x20746d66, Endian.little) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 3, Endian.little) // IEEE float
      ..setUint16(22, 2, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 8, Endian.little)
      ..setUint16(32, 8, Endian.little)
      ..setUint16(34, 32, Endian.little)
      ..setUint32(36, 0x61746164, Endian.little) // data
      ..setUint32(40, data, Endian.little);
    _f
      ..setPositionSync(0)
      ..writeFromSync(h.buffer.asUint8List())
      ..closeSync();
  }
}
