// The allocation lint on its fixture: every expected place, nothing else.
import 'dart:io';

import 'package:test/test.dart';

import '../src/alloc/program.dart';
import '../src/alloc/sdk.dart';
import '../src/alloc/walk.dart';

void main() {
  late Walk walk;
  late String fixture;
  const frame = 'tools/lint/test/alloc_fixture/frame.dart';

  setUpAll(() async {
    final root = Process.runSync('git', [
      'rev-parse',
      '--show-toplevel',
    ]).stdout.toString().trim();
    fixture = File('$root/$frame').readAsStringSync();
    final program = Program();
    await loadProgram(
      program,
      root,
      ['$root/tools/lint/test/alloc_fixture'],
      (_) => 'fixture',
      (m) => fail(m),
    );
    final roots = program.decls.keys.where(
      (id) => id.endsWith('::frame') || id.endsWith('::bind'),
    );
    expect(roots, hasLength(2));
    walk = Walk(program, SdkVerdicts.read('$root/tools/lint/alloc_sdk.txt'))
      ..run(roots);
  });

  test('each line reports the kinds it expects and no others', () {
    final want = <int, List<String>>{};
    final lines = fixture.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final m = RegExp(r'// expect: (.*)$').firstMatch(lines[i]);
      if (m == null) continue;
      // Alone on a line (where the formatter put it): the line above.
      final alone = lines[i].trimLeft().startsWith('//');
      want[alone ? i : i + 1] = m[1]!.trim().split(' ')..sort();
    }
    final got = <int, List<String>>{};
    for (final h in walk.hits.where((h) => h.accepted == null)) {
      got.putIfAbsent(h.line, () => []).add(h.kind);
    }
    for (final l in got.values) {
      l.sort();
    }
    expect(got, want);
  });

  test('a marked place is accepted with its reason', () {
    final accepted = walk.hits.where((h) => h.accepted != null).toList();
    expect(accepted.map((h) => (h.kind, h.accepted)), [
      ('new', "the frame's own result"),
    ]);
  });

  test('a cold function ends the walk; a call reaches the overrides in the '
      "receiver's subtypes only", () {
    expect(walk.cold.keys.single, endsWith('::_load'));
    expect(walk.from.keys.where((id) => id.contains('Apart')), isEmpty);
    expect(walk.from.keys.where((id) => id.contains('Circle.area')), [
      isNotNull,
    ]);
  });

  test('a kept tear-off makes its target reachable, with the chain', () {
    final visit = walk.from.keys.singleWhere(
      (id) => id.endsWith('Kept._visit'),
    );
    expect(walk.chain(visit).first, endsWith('::frame'));
  });
}
