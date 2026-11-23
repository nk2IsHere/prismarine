import 'dart:typed_data';

/// Decoded audio as interleaved float32 frames.
abstract class PcmSource {
  int get channels;
  int get sampleRate;

  /// The total number of frames. A source whose length comes from the
  /// metadata of a container may count more frames than the decoded file
  /// holds.
  int get frames;

  /// Copies up to [count] interleaved frames, starting at [frame], into
  /// [out]. Returns the number of frames copied, which is 0 at or past the
  /// end.
  int read(Float32List out, int frame, int count);
}

/// A source whose data is still loading off the render thread. A player
/// decides what a sound on it does until [ready], such as starting late from
/// its first sample or holding its timeline.
abstract interface class LoadingPcmSource implements PcmSource {
  bool get ready;
}

/// Returns true when [s] has its data.
bool pcmReady(PcmSource s) => s is! LoadingPcmSource || s.ready;

/// A whole decoded file in memory.
class MemoryPcmSource implements PcmSource {
  MemoryPcmSource(
    this.samples, {
    required this.channels,
    required this.sampleRate,
  });

  final Float32List samples;
  @override
  final int channels, sampleRate;

  @override
  int get frames => samples.length ~/ channels;

  @override
  int read(Float32List out, int frame, int count) {
    if (frame < 0 || frame >= frames) return 0;
    final n = (frames - frame).clamp(0, count);
    out.setRange(0, n * channels, samples, frame * channels);
    return n;
  }
}
