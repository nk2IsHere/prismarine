/// Runtime time from the audio output (spec "Data flow per frame"): the time
/// the device has consumed minus the output latency, i.e. what is audible;
/// it never runs backwards (an underrun stalls it).
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
