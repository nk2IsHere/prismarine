/// Writes the parity session of the synthetic project into a directory, with
/// its samples as raw float32 files. The `parity` example of
/// prismarine_audio_out replays it on the native engine and compares the
/// bits.
///
/// Run it with `dart run tool/synthetic_parity.dart <dir>`, then
/// `cargo run --release --example parity -- <dir>` in
/// prismarine_audio_out's `native/`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:prismarine_audio/testing.dart';

import '../test/support/synthetic.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/synthetic_parity.dart <dir>');
    exitCode = 2;
    return;
  }
  final dir = Directory(args.first)..createSync(recursive: true);
  final p = SyntheticProject(dir: dir.path);
  final pcm = <String, (String, int, int)>{};
  for (final MapEntry(:key, value: s) in p.samples.entries) {
    final path = '${dir.path}/$key.f32';
    final b = Float32List(s.frames * s.channels);
    s.read(b, 0, s.frames);
    File(path).writeAsBytesSync(b.buffer.asUint8List());
    pcm[path] = (path, s.channels, s.sampleRate);
    // A slot sound is the file `<soundDir>/<key>`.
    final slot = '${dir.path}/$key';
    File(slot).writeAsBytesSync(b.buffer.asUint8List());
    pcm[slot] = (slot, s.channels, s.sampleRate);
  }
  final events = p.events();
  final checksum = writeParitySession(
    out: dir.path,
    blob: projectBlob(
      events: {
        for (final e in events.entries)
          if (!e.value.isMixState) e.key: e.value,
      },
      mixStates: {
        for (final e in events.entries)
          if (e.value.isMixState) e.key: e.value,
      },
      mixer: p.mixer(),
    ),
    engine: p.engine(),
    script: SyntheticProject.script(),
    total: SyntheticProject.frames,
    seed: 3,
    soundDir: dir.path,
    pcm: pcm,
  );
  stdout.writeln('dart render checksum $checksum');
}
