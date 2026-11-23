import 'dart:math' as math;
import 'dart:typed_data';

import '../events/instance.dart';
import '../events/player.dart';
import '../mixer/graph.dart';
import '../mixer/mix_state.dart';
import '../model/model.dart';
import '../pcm_source.dart';

/// What the runtime asks of the audio (sendable to a render isolate).
sealed class AudioCommand {
  const AudioCommand(this.id);

  /// The instance (event or snapshot) the command addresses.
  final int id;
}

/// Starts event [path] [seek] seconds in. [sound] is the key of the sound
/// that its programmer instruments play, which the engine's [SoundLoader]
/// resolves. With [late], a tolerance in seconds, [seek] is the position
/// the instance should be at by now: it is used only when it is past the
/// tolerance and [AudioRules.lateStartMinimum] and the event is longer than
/// the tolerance, and a position past the event's end does not play. The
/// length of an event with a sound is the sound's.
class StartEvent extends AudioCommand {
  const StartEvent(super.id, this.path, {this.seek = 0, this.sound, this.late});
  final String path;
  final double seek;
  final String? sound;
  final double? late;
}

class SetParameter extends AudioCommand {
  const SetParameter(super.id, this.name, this.value);
  final String name;
  final double value;
}

/// EventInstance volume (linear). With [keepTail], a zero volume for a
/// one-shot instance that has played and has less than [keepTail] seconds
/// left is ignored.
class SetVolume extends AudioCommand {
  const SetVolume(super.id, this.volume, {this.keepTail});
  final double volume;
  final double? keepTail;
}

/// Stops an instance: with a fade (an AHDSR release or a short declick) or
/// at once. With [viaParameter], a fading stop sets that parameter to 1 in
/// place of stopping when the event has it. With [keepTail], a one-shot
/// instance with less than [keepTail] seconds left plays on.
class StopEvent extends AudioCommand {
  const StopEvent(
    super.id, {
    this.fade = true,
    this.viaParameter,
    this.keepTail,
  });
  final bool fade;
  final String? viaParameter;
  final double? keepTail;
}

/// A paused event is silent and doesn't advance; resuming continues in
/// place.
class SetPaused extends AudioCommand {
  const SetPaused(super.id, this.paused);
  final bool paused;
}

/// The event's position relative to the listener: [azimuth] degrees (0
/// ahead, +90 right), [distance], and the cone angle [cone] (degrees between
/// the event's forward and the listener).
class SetSpatial extends AudioCommand {
  const SetSpatial(super.id, this.azimuth, this.distance, [this.cone = 0]);
  final double azimuth, distance, cone;
}

class StartMixState extends AudioCommand {
  const StartMixState(super.id, this.path);
  final String path;
}

class SetMixStateParameter extends AudioCommand {
  const SetMixStateParameter(super.id, this.name, this.value);
  final String name;
  final double value;
}

class StopMixState extends AudioCommand {
  const StopMixState(super.id);
}

/// Settings of an engine that hold for every command.
class AudioRules {
  const AudioRules({
    this.reportLag = 0,
    this.lateStartMinimum = 0,
    this.wholeMsLengths = false,
  });

  /// Frames by which the reported position of an instance trails its
  /// render, which [SetVolume.keepTail] and [StopEvent.keepTail] count.
  final int reportLag;

  /// A late start's position at or under this many seconds starts at 0.
  final double lateStartMinimum;

  /// A sound's length for a late start is rounded down to whole ms.
  final bool wholeMsLengths;
}

/// Where the bridge sends audio commands: lockstep (capture) or real time.
abstract interface class AudioSink {
  /// Applies [c] at runtime time [at] (seconds), or as soon as possible.
  void command(AudioCommand c, {double? at});
}

/// A sound key → its decoded samples (the host decodes).
typedef SoundLoader = PcmSource? Function(String key);

/// What renders a session's audio: the Dart [AudioEngine] or the native
/// mixer (mcsm_audio_out `NativeAudioEngine`), which render the same bits.
abstract interface class AudioRenderer {
  /// Frames rendered so far (the render head). Setting it moves the head
  /// without rendering (a capture's fast-forward: audio.wav starts where
  /// it stops); commands scheduled at or before it apply at the next frame.
  int get position;
  set position(int frames);

  /// Applies [c] when the render head reaches frame [at] (now, if it has).
  void schedule(AudioCommand c, {required int at});

  /// Applies [c] before the next frame.
  void apply(AudioCommand c);

  /// [frames] of the master (stereo), applying scheduled commands at their
  /// frames.
  Float32List render(int frames);

  Set<String> get problems;
}

/// The audio of one session: an [EventPlayer] into a [MixerGraph], driven by
/// [AudioCommand]s applied at exact frames. Rendering is deterministic.
class AudioEngine implements AudioRenderer {
  /// [events] by path; an instance without an input bus plays into the
  /// mixer bus [defaultBus].
  AudioEngine(
    Map<String, EventDef> events,
    this.mixer,
    SampleLoader samples, {
    this.sounds,
    int seed = 0,
    void Function(String)? log,
    this.rules = const AudioRules(),
    String? defaultBus,
  }) : player = EventPlayer(
         events,
         samples,
         seed: seed,
         log: log,
         defaultBus: defaultBus ?? mixer.masterPath ?? '',
       ) {
    player.startMixState = mixer.startMixStateDef;
  }

  final EventPlayer player;
  final MixerGraph mixer;
  final SoundLoader? sounds;
  final AudioRules rules;

  /// Frames rendered so far (the render head).
  @override
  int position = 0;

  final _events = <int, EventInstance>{};
  final _snapshots = <int, MixStateInstance>{};
  final _queue = <(int, int, AudioCommand)>[];
  int _seq = 0;
  final _problems = <String>{};

  @override
  Set<String> get problems => {
    ..._problems,
    ...player.problems,
    ...mixer.problems,
  };

  EventInstance? instance(int id) => _events[id];

  @override
  void schedule(AudioCommand c, {required int at}) {
    _queue.add((at, _seq++, c));
    _queue.sort((a, b) {
      final k = a.$1.compareTo(b.$1);
      return k != 0 ? k : a.$2.compareTo(b.$2);
    });
  }

  @override
  void apply(AudioCommand c) {
    switch (c) {
      case StartEvent(:final id, :final path, :final sound, :final late):
        PcmSource? prog;
        if (sound != null) {
          prog = sounds?.call(sound);
          if (prog == null) _problem('no voice $sound');
        }
        var seek = c.seek;
        if (late != null) {
          // The instance's length: its timeline's, or its sound's when it
          // has one, in whole ms by the rules.
          final double len;
          if (prog != null) {
            len = rules.wholeMsLengths
                ? (prog.frames * 1000 ~/ prog.sampleRate) / 1000
                : prog.frames / prog.sampleRate;
          } else {
            len = (player.event(path)?.timeline.length ?? 0) / timelineRate;
          }
          // A wanted position past the tolerance that is also past the
          // end does not play; else it is the offset when the instance is
          // longer than the tolerance and it is past the minimum.
          final past = seek > 0 && seek > late ? seek : -1.0;
          if (len > 0 && past > len) return;
          seek = late >= len || rules.lateStartMinimum >= seek
              ? 0
              : math.max(past, 0);
        }
        // An offset seeks the event's timeline. A programmer instrument on
        // a parameter sheet still plays from its start [ORACLE fmod].
        final i = player.start(path, seek: seek, slot: prog);
        if (i != null) {
          _events[id] = i;
        } else if (player.has(path)) {
          // Refused by its polyphony: it plays nothing, quietly.
          _ended.add(id);
        }
      case SetParameter(:final id, :final name, :final value):
        _event(id)?.setParameter(name, value);
      case SetVolume(:final id, :final volume, :final keepTail):
        final i = _event(id);
        if (i == null) return;
        // A volume sent before the instance has played is the one it starts
        // with.
        if (keepTail != null &&
            volume.abs() <= 1e-6 &&
            i.def.oneShot &&
            i.hasPlayed &&
            _left(i) < keepTail) {
          return;
        }
        i.volume = volume;
      case StopEvent(:final id, :final fade, :final viaParameter):
        final i = _events[id];
        if (i == null || i.isDone) return;
        if (c.keepTail case final k? when i.def.oneShot && _left(i) < k) {
          return;
        }
        if (!fade) {
          i.stop(fade: false);
        } else if (viaParameter == null || !i.setParameter(viaParameter, 1)) {
          i.stop();
        }
      case SetSpatial(:final id, :final azimuth, :final distance, :final cone):
        _event(id)?.setSpatial(azimuth, distance, cone);
      case SetPaused(:final id, :final paused):
        _event(id)?.paused = paused;
      case StartMixState(:final id, :final path):
        final s = mixer.startMixState(path);
        if (s != null) _snapshots[id] = s;
      case SetMixStateParameter(:final id, :final name, :final value):
        _snapshot(id)?.setParameter(name, value);
      case StopMixState(:final id):
        _snapshot(id)?.stop();
        _snapshots.remove(id);
    }
  }

  /// An instance's length minus its reported position, in seconds: a
  /// programmer sound's when it has one. The reported position trails the
  /// render by [AudioRules.reportLag].
  double _left(EventInstance i) =>
      (i.slotLeft ?? (i.def.timeline.length - i.cursor) / timelineRate) +
      rules.reportLag / timelineRate;

  /// Instances that ran out: later commands to them are dropped quietly.
  final _ended = <int>{};

  EventInstance? _event(int id) {
    final i = _events[id];
    if (i == null && !_ended.contains(id)) _problem('no event instance $id');
    return i;
  }

  MixStateInstance? _snapshot(int id) {
    final s = _snapshots[id];
    if (s == null) _problem('no snapshot instance $id');
    return s;
  }

  void _problem(String m) => _problems.add(m);

  @override
  Float32List render(int frames) {
    final out = Float32List(frames * 2);
    var done = 0;
    while (done < frames) {
      while (_queue.isNotEmpty && _queue.first.$1 <= position) {
        apply(_queue.removeAt(0).$3);
      }
      var n = frames - done;
      if (_queue.isNotEmpty) {
        final next = _queue.first.$1 - position;
        if (next < n) n = next;
      }
      final block = mixer.render(
        player.render(n),
        n,
        inputs51: player.outputs51,
      );
      out.setRange(done * 2, (done + n) * 2, block);
      done += n;
      position += n;
      _events.removeWhere((id, i) {
        if (!i.isDone) return false;
        _ended.add(id);
        return true;
      });
    }
    return out;
  }
}
