import 'dart:typed_data';

import 'route.dart';
import 'snapshot_format.dart';

/// A simulation that a route drives. The same start, seed and frames give
/// the same state.
abstract interface class ReplaySim {
  /// The simulated time in seconds.
  double get time;

  /// The frames stepped so far.
  int get frame;

  /// A count that grows each time a scene opens.
  int get sceneOpens;

  /// True on a frame that the host does not draw anyway.
  bool get frameHeld;

  /// Runs one frame of [dt] seconds with the host objects of a headless run.
  void step(double dt);
}

/// The game side of a replay with its route reader, its sims and its state
/// codecs.
abstract interface class ReplayGame<
  S extends ReplaySim,
  R extends RouteReader
> {
  /// The format of the game's snapshots.
  SnapshotFormat get snapshots;

  /// Reads [lines], a header and frame lines, into the game's reader.
  R route(List<String> lines, {String? path});

  /// Makes a sim as the recorded host made it, without a boot. [config]
  /// holds the host's settings.
  S open(R route, Map<String, Object?> config);

  /// Boots [sim] at the start of [route].
  void boot(S sim, R route, Map<String, Object?> config);

  /// Runs after the boot or the restore of [sim]. Makes the host objects
  /// that a snapshot's tail fills.
  void started(S sim, Map<String, Object?> config);

  /// Applies the next frame of [route] to [sim] before its step. Returns the
  /// frame's dt, or null at the end of the route.
  double? input(S sim, R route);

  /// Writes the state of [sim] between two frames as a snapshot body.
  Uint8List writeState(S sim);

  /// Reads [body] into [sim], which [open] made.
  void readState(S sim, Uint8List body);

  /// Returns the game's fields of the header of a snapshot of [sim].
  Map<String, Object?> snapshotFields(S sim);

  /// Returns the folders that hold the snapshots of [route].
  List<String> snapshotDirs(R route);

  /// Releases the host resources of [sim] at the end of a run, such as its
  /// load workers.
  void close(S sim);
}
