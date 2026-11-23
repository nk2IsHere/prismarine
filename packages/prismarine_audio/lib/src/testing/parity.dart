import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/engine.dart';

/// Writes a parity session into [out] for the `parity` example of the crate
/// of prismarine_audio_out, which replays it on the native engine and
/// compares the bits. Schedules [script] on [engine], renders [total]
/// frames, writes the project's [blob], the script, the decoded samples of
/// [pcm], the render, the problems and the settings, and returns the FNV-1a
/// 64 checksum of the render's float32 bytes in hex.
///
/// [script] is in time order. A start's sound key resolves to
/// `<soundDir>/<key>`. [pcm] maps each sample file that the engine played to
/// a raw float32 file with its channel count and rate.
String writeParitySession({
  required String out,
  required Uint8List blob,
  required AudioEngine engine,
  required List<(int, AudioCommand)> script,
  required int total,
  required int seed,
  required String soundDir,
  required Map<String, (String, int, int)> pcm,
}) {
  Directory(out).createSync(recursive: true);
  File('$out/model.bin').writeAsBytesSync(blob);
  final lines = StringBuffer();
  for (final (at, c) in script) {
    engine.schedule(c, at: at);
    lines.writeln(parityLine(at, c, soundDir));
  }
  File('$out/script.tsv').writeAsStringSync(lines.toString());
  final f = File('$out/dart.f32').openSync(mode: FileMode.write);
  var sum = 0xcbf29ce484222325;
  while (engine.position < total) {
    final n = math.min(1024, total - engine.position);
    final b = engine.render(n);
    final bytes = b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
    for (final x in bytes) {
      sum = (sum ^ x) * 0x100000001b3;
    }
    f.writeFromSync(bytes);
  }
  f.closeSync();
  File('$out/pcm.tsv').writeAsStringSync(
    [
      for (final MapEntry(:key, value: (file, ch, r)) in pcm.entries)
        '$key\t$file\t$ch\t$r',
    ].join('\n'),
  );
  File(
    '$out/problems.txt',
  ).writeAsStringSync((engine.problems.toList()..sort()).join('\n'));
  final r = engine.rules;
  File('$out/meta.txt').writeAsStringSync(
    '$seed $total ${r.reportLag} ${r.lateStartMinimum} '
    '${r.wholeMsLengths ? 1 : 0}\n',
  );
  String hex32(int v) => v.toRadixString(16).padLeft(8, '0');
  return hex32(sum >>> 32) + hex32(sum & 0xffffffff);
}

/// Returns one line of a parity script, the command [c] at frame [at] as
/// the arguments of a post to the native engine, separated by tabs.
String parityLine(int at, AudioCommand c, String soundDir) {
  String row(
    int op, {
    double value = 0,
    double seek = 0,
    double? late,
    bool flag = false,
    double? keepTail,
    String name = '-',
    String sound = '-',
    String via = '-',
  }) => [
    at,
    op,
    c.id,
    value,
    seek,
    late == null ? 0 : 1,
    late ?? 0,
    flag ? 1 : 0,
    keepTail ?? -1,
    name,
    sound,
    via,
  ].join('\t');
  return switch (c) {
    StartEvent(:final path, :final seek, :final sound, :final late) => row(
      1,
      seek: seek,
      late: late,
      name: path,
      sound: sound == null ? '-' : '$soundDir/$sound',
    ),
    SetParameter(:final name, :final value) => row(
      2,
      value: value,
      name: name.toLowerCase(),
    ),
    SetVolume(:final volume, :final keepTail) => row(
      3,
      value: volume,
      keepTail: keepTail,
    ),
    StopEvent(:final fade, :final keepTail, :final viaParameter) => row(
      4,
      flag: !fade,
      keepTail: keepTail,
      via: viaParameter?.toLowerCase() ?? '-',
    ),
    SetPaused(:final paused) => row(5, flag: paused),
    StartMixState(:final path) => row(7, name: path),
    SetMixStateParameter(:final name, :final value) => row(
      8,
      value: value,
      name: name.toLowerCase(),
    ),
    StopMixState() => row(9),
    SetSpatial(:final azimuth, :final distance, :final cone) => row(
      12,
      value: azimuth,
      seek: distance,
      late: cone,
    ),
  };
}
