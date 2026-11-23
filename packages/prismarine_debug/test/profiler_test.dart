import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

void main() {
  test('frames accumulate sections and flush one JSON line each', () async {
    final dir = Directory.systemTemp.createTempSync('prof');
    final p = FrameProfiler(dir.path);
    p.beginFrame(t: 0, dt: 0);
    p.add('look.solve', 2);
    p.add('look.solve', 3);
    p.beginFrame(t: 1 / 30, dt: 1 / 30);
    p.add('binding.apply', 1.5);
    await p.close();
    final lines = File('${dir.path}/frames.jsonl').readAsLinesSync();
    expect(lines, hasLength(2));
    expect(jsonDecode(lines[0])['look.solve'], 5);
    expect(jsonDecode(lines[1])['binding.apply'], 1.5);
    expect(File('${dir.path}/summary.txt').existsSync(), isTrue);
  });

  test('summarize: p50/p95/max per section inside each window', () {
    final frames = [
      for (var i = 0; i < 100; i++) {'t': i * 0.1, 'a': i.toDouble()},
    ];
    final s = summarize(frames, [('w', 0, 5)]);
    expect(s, contains('== w: 50 frames'));
    expect(
      s,
      contains(RegExp(r'a\s+p50\s+25\.00\s+p95\s+47\.00\s+max\s+49\.00')),
    );
  });
}
