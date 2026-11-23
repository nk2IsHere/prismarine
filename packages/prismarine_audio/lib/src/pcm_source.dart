import 'dart:typed_data';

/// Decoded audio the player reads: interleaved float32 frames.
abstract class PcmSource {
  int get channels;
  int get sampleRate;

  /// Total frames (a voice MP3's FSB `numSamples` is padded to whole 1152
  /// frames; the chore block is the authority on its length).
  int get frames;

  /// Copies up to [count] frames from [frame] into [out] (interleaved);
  /// returns the frames copied (0 at or past the end).
  int read(Float32List out, int frame, int count);
}

/// A source whose data is still loading off the render thread: an
/// instrument on it starts late
/// from its first sample once [ready] (FMOD 1.06 doesn't wait for sample
/// data); a timelocked one holds its event's timeline, as 1.06 holds a
/// stream's.
abstract interface class LoadingPcmSource implements PcmSource {
  bool get ready;
}

/// Whether [s] has its data.
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
