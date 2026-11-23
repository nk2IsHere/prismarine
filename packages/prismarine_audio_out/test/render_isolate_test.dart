import 'dart:async';
import 'dart:typed_data';

import 'package:prismarine_audio_out/prismarine_audio_out.dart';
import 'package:test/test.dart';

/// Renders a constant level, which a ('level', v) message sets. Reports
/// every other message as a problem.
class _Level implements IsolateRenderer {
  _Level(this.host);
  final RenderHost host;
  double level = 0.25;

  @override
  Float32List render(int frames) =>
      Float32List(frames * 2)..fillRange(0, frames * 2, level);

  @override
  void receive(Object? message) {
    switch (message) {
      case ('level', final double v):
        level = v;
      default:
        host.problem('unknown message $message');
    }
  }

  @override
  void stop() {}
}

IsolateRenderer _make(RenderHost host) => _Level(host);

void main() {
  test('blocks come back in request order and messages reach the '
      'renderer', () async {
    final r = await RenderIsolate.spawn(_make);
    addTearDown(r.dispose);
    final problems = <String>[];
    r.problems.listen(problems.add);
    final blocks = <Float32List>[];
    final sub = r.blocks.listen(blocks.add);
    r.render(480);
    r.send(('level', 0.5));
    r.render(960);
    r.send('ping');
    final sw = Stopwatch()..start();
    while ((blocks.length < 2 || problems.isEmpty) &&
        sw.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await sub.cancel();
    expect([for (final b in blocks) b.length], [960, 1920]);
    expect(blocks[0].every((v) => v == 0.25), isTrue);
    expect(blocks[1].every((v) => v == 0.5), isTrue);
    expect(problems, ['unknown message ping']);
  });

  test('dispose waits for the isolate to exit before it closes the ports, and '
      'no reply reaches a closed stream', () async {
    final r = await RenderIsolate.spawn(_make);
    final errors = <Object>[];
    await runZonedGuarded(() async {
      for (var i = 0; i < 20; i++) {
        r.render(960);
      }
      await r.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
  });
}
