import 'dart:typed_data';

import 'package:prismarine_audio/prismarine_audio.dart';
import 'package:test/test.dart';

import 'support/synthetic.dart';

/// FNV-1a 64 of the float32 bytes, in hex.
String _checksum(List<Float32List> blocks) {
  var sum = 0xcbf29ce484222325;
  for (final b in blocks) {
    for (final x in b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes)) {
      sum = (sum ^ x) * 0x100000001b3;
    }
  }
  String hex32(int v) => v.toRadixString(16).padLeft(8, '0');
  return hex32(sum >>> 32) + hex32(sum & 0xffffffff);
}

List<Float32List> _render(AudioEngine e) {
  for (final (at, c) in SyntheticProject.script()) {
    e.schedule(c, at: at);
  }
  final out = <Float32List>[];
  while (e.position < SyntheticProject.frames) {
    final n = SyntheticProject.frames - e.position;
    out.add(e.render(n < 1024 ? n : 1024));
  }
  return out;
}

void main() {
  test('the synthetic project renders without problems and with sound', () {
    final e = SyntheticProject().engine();
    final out = _render(e);
    expect(e.problems, isEmpty);
    var peak = 0.0;
    for (final b in out) {
      for (final v in b) {
        if (v.abs() > peak) peak = v.abs();
      }
    }
    expect(peak, greaterThan(0.01));
    expect(peak, lessThan(4));
  });

  test('the synthetic render has the same bits on every platform', () {
    // A deliberate change to the render or to the project changes it.
    expect(_checksum(_render(SyntheticProject().engine())), 'e91d46ef22de4c15');
  });

  test('two engines with the same seed render the same bits', () {
    expect(
      _checksum(_render(SyntheticProject().engine(seed: 9))),
      _checksum(_render(SyntheticProject().engine(seed: 9))),
    );
  });

  test('the project writes a blob for the native engine', () {
    final p = SyntheticProject();
    final events = p.events();
    final blob = projectBlob(
      events: {
        for (final e in events.entries)
          if (!e.value.isMixState) e.key: e.value,
      },
      mixStates: {
        for (final e in events.entries)
          if (e.value.isMixState) e.key: e.value,
      },
      mixer: p.mixer(),
    );
    expect(blob.buffer.asByteData().getInt32(0, Endian.little), 0x584D434D);
    expect(blob.buffer.asByteData().getInt32(4, Endian.little), 2);
  });
}
