import 'dart:typed_data';

import '../mixer/mix_state.dart';
import '../model/model.dart';
import '../pcm_source.dart';
import 'instance.dart';
import 'rng.dart';

/// Loads a waveform's samples (decoding is the host's: `mcsm_audio_out`);
/// null when it can't.
typedef SampleLoader = PcmSource? Function(WaveformDef w);

/// Plays FMOD Studio events from the slice's converted banks, deterministically
/// at 48 kHz (plan 3d Task 4). Each instance renders into its input bus's
/// mixer bus; the mixer graph (Task 5) takes it from there.
class EventPlayer {
  /// [events] by path. An instance without an input bus plays into the
  /// mixer bus [defaultBus].
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

  /// The most low-level channels played at once so far (after a block):
  /// FMOD 1.06 virtualises the quietest past 64 (GameApp.exe initializes
  /// Studio with 128 channels and keeps the 64 software ones; see
  /// formats/telltale/fmod-runtime.md, "Polyphony").
  int peakChannels = 0;

  /// Starts a snapshot on the mixer (an event instrument on a snapshot);
  /// null when there is no mixer.
  MixStateInstance? Function(EventDef def)? startMixState;

  /// Live instances, in start order.
  final instances = <EventInstance>[];

  /// Each problem once: unknown events, missing samples, unsupported content.
  final problems = <String>{};

  void problem(String message) {
    if (problems.add(message)) log?.call(message);
  }

  bool has(String path) => _events.containsKey(path);
  EventDef? event(String path) => _events[path];

  /// Starts [path] [seek] seconds into its timeline; [programmer] is the
  /// sound its programmer instruments play. Null (and a problem) for an
  /// unknown event.
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

  /// FMOD's event polyphony (O, fmod.dll 1.06.02 with patched banks;
  /// docs/formats/fmod-bank.md "Polyphony"): with [EventDef.maxPolyphony]
  /// instances live, a new start fails (behaviour 0: the instance reports
  /// stopped and plays nothing) or stops the oldest (2: it is cut one mix
  /// block later). Instances already cut don't count. False: refused.
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

  /// [w]'s samples, loaded once.
  PcmSource? sample(WaveformDef w) => _samples.putIfAbsent(w.key, () {
    final s = loadSample(w);
    if (s == null) problem('no sample ${w.label}');
    return s;
  });

  /// Forgets the loaded samples (a scene change in real time: the host's
  /// cache keeps what is still wanted; playing instances keep their own).
  void forgetSamples() => _samples.clear();

  /// The last [render]'s 5.1 outputs (S2 events whose output is 5.1),
  /// summed per output bus path.
  final outputs51 = <String, Float32List>{};

  /// Renders [frames] of every live instance, summed per output bus path
  /// (stereo, interleaved; 5.1 ones in [outputs51]); finished instances are
  /// dropped.
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
