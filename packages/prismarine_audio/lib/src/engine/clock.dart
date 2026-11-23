/// The time that is audible now, the seconds that the output device has
/// consumed minus the output latency. The time does not run backwards, and
/// it stands still while the device starves.
class AudioClock {
  AudioClock({required this.consumed, this.latency = 0});

  /// Seconds of audio the device has consumed.
  final double Function() consumed;
  final double latency;
  double _last = 0;

  double now() {
    final t = consumed() - latency;
    if (t > _last) _last = t;
    return _last;
  }
}
