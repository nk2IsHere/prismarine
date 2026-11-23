import 'dart:io';

import 'io.dart';

/// A difference that a comparison found at a frame.
class Divergence {
  Divergence(this.channel, this.frame, this.t, this.scene, this.detail);
  final String channel;
  final int frame;
  final double t;
  final String scene, detail;

  Map<String, Object?> toJson() => {
    'channel': channel,
    'frame': frame,
    't': t,
    'scene': scene,
    'detail': detail,
  };
}

/// Writes the first divergences of run [id] to [o], earliest first, or that
/// the run is the same. Each entry of [first] is a [Divergence] or its JSON.
void printFirst(StringSink o, String id, List<Object?> first) {
  final ds = [
    for (final d in first)
      d is Divergence ? d.toJson() : (d! as Map).cast<String, Object?>(),
  ]..sort((x, y) => (x['frame'] as int).compareTo(y['frame'] as int));
  if (ds.isEmpty) {
    o.writeln('$id: same');
    return;
  }
  final e = ds.first;
  o.writeln(
    '$id: DIVERGES at t ${(e['t'] as num).toStringAsFixed(3)} '
    '(frame ${e['frame']}) in ${e['scene']}',
  );
  for (final d in ds) {
    o.writeln(
      '  ${'${d['channel']}'.padRight(7)} t ${(d['t'] as num).toStringAsFixed(3)}'
      ' ${d['scene']}: ${d['detail']}',
    );
  }
}

/// The note of the divergences that a change explains. A line has the form
/// `<id or glob> [<channel>,…] # why`.
class CorpusExpect {
  CorpusExpect(this.entries);
  final List<(String, Set<String>, String)> entries;

  /// Reads the note at [path]. A missing note explains nothing.
  static CorpusExpect load(String? path) {
    if (path == null || !File(path).existsSync()) return CorpusExpect(const []);
    final e = <(String, Set<String>, String)>[];
    for (var l in File(path).readAsLinesSync()) {
      final hash = l.indexOf('#');
      final why = hash < 0 ? '' : l.substring(hash + 1).trim();
      if (hash >= 0) l = l.substring(0, hash);
      final parts = l.trim().split(RegExp(r'\s+'));
      if (parts.first.isEmpty) continue;
      e.add((
        parts.first,
        parts.length > 1 ? parts[1].split(',').toSet() : <String>{},
        why,
      ));
    }
    return CorpusExpect(e);
  }

  /// Returns the reason that explains a divergence of run [id] in
  /// [channels], or null.
  String? explains(String id, Set<String> channels) {
    for (final (pattern, chans, why) in entries) {
      if (!glob(pattern, id)) continue;
      if (chans.isEmpty || channels.every(chans.contains)) {
        return why.isEmpty ? '(listed)' : why;
      }
    }
    return null;
  }
}
