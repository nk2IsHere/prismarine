import 'dart:typed_data';

import '../mixer/mix_state.dart';
import '../model/model.dart';
import '../pcm_source.dart';
import 'instance.dart';
import 'rng.dart';

/// Returns the decoded samples of a waveform, or null when it does not load.
typedef SampleLoader = PcmSource? Function(WaveformDef w);

/// Plays the events of a project, deterministically at 48 kHz. Each instance
/// renders into the mixer bus of its input bus and a [MixerGraph] mixes the
/// buses.
class EventPlayer {
  /// [events] are keyed by path. An instance without an input bus plays into
  /// the mixer bus [defaultBus].
  EventPlayer(
    Map<String, EventDef> events,
    this.loadSample, {
    this.seed = 0,
    this.log,
    required this.defaultBus,
  }) : _events = events;

  final SampleLoader loadSample;
  final int seed;
  final void Function(String message)? log;
  final String defaultBus;
  final Map<String, EventDef> _events;
  final _samples = <String, PcmSource?>{};
  int _started = 0;

  /// The most sounds played at once so far, counted after each block.
  int peakChannels = 0;

  /// Starts a mix state on the mixer for a mix state instrument, null
  /// without a mixer.
  MixStateInstance? Function(EventDef def)? startMixState;

  /// The live instances in start order.
  final instances = <EventInstance>[];

  /// Each problem once, such as an unknown event, a missing sample or an
  /// unsupported instrument.
  final problems = <String>{};

  void problem(String message) {
    if (problems.add(message)) log?.call(message);
  }

  bool has(String path) => _events.containsKey(path);
  EventDef? event(String path) => _events[path];

  /// Starts [path] [seek] seconds into its timeline. [slot] is the sound that
  /// its slot instruments play. Returns null for an unknown event, with a
  /// problem and for a start that the polyphony limit refuses.
  EventInstance? start(String path, {double seek = 0, PcmSource? slot}) {
    final hit = _events[path];
    if (hit == null) {
      problem('unknown event $path');
      return null;
    }
    if (!_admit(hit)) return null;
    final i = EventInstance(
      this,
      hit,
      Rng(seed * 0x9e3779b1 + ++_started),
      slot: slot,
      seek: seek,
    );
    instances.add(i);
    return i;
  }

  /// Applies the polyphony limit of [d]. With [EventDef.maxPolyphony]
  /// instances live, a new start fails or stops the oldest, which is cut one
  /// block later. Instances already cut do not count. Returns false for a
  /// refused start.
  bool _admit(EventDef d) {
    if (d.maxPolyphony <= 0) return true;
    EventInstance? oldest;
    var live = 0;
    for (final i in instances) {
      if (!identical(i.def, d) || i.isDone || i.isStolen) continue;
      oldest ??= i;
      live++;
    }
    if (live < d.maxPolyphony) return true;
    switch (d.polyphonyMode) {
      case PolyphonyMode.failNew:
        return false;
      case PolyphonyMode.stealOldest:
        oldest!.steal();
        return true;
    }
  }

  /// Returns the samples of [w], loaded once.
  PcmSource? sample(WaveformDef w) => _samples.putIfAbsent(w.key, () {
    final s = loadSample(w);
    if (s == null) problem('no sample ${w.label}');
    return s;
  });

  /// Forgets the loaded samples. Playing instances keep their own.
  void forgetSamples() => _samples.clear();

  /// The 5.1 outputs of the last [render], of the events whose output is
  /// 5.1, summed by output bus path.
  final outputs51 = <String, Float32List>{};

  /// Renders [frames] frames of every live instance, summed by output bus
  /// path in interleaved stereo, with the 5.1 ones in [outputs51]. Finished
  /// instances are dropped.
  Map<String, Float32List> render(int frames) {
    final out = <String, Float32List>{};
    outputs51.clear();
    for (final i in [...instances]) {
      final buf = i.outputChannels == 6
          ? outputs51.putIfAbsent(i.outputPath, () => Float32List(frames * 6))
          : out.putIfAbsent(i.outputPath, () => Float32List(frames * 2));
      i.render(buf, frames);
      for (final MapEntry(:key, :value) in i.sendOutputs.entries) {
        final o = out.putIfAbsent(key, () => Float32List(frames * 2));
        for (var k = 0; k < value.length; k++) {
          o[k] += value[k];
        }
      }
      if (i.isDone) instances.remove(i);
    }
    var channels = 0;
    for (final i in instances) {
      channels += i.channels;
    }
    if (channels > peakChannels) peakChannels = channels;
    return out;
  }
}
