import 'package:flutter_test/flutter_test.dart';
// The cache is the renderer's own, not part of the package's API.
// ignore: implementation_imports
import 'package:prismarine_render/src/loose_map.dart';

class _Gpu {
  _Gpu(this.name);
  final String name;
}

// Tests the entries that a release keeps held whenever the collector runs. It
// also tests that a loosened value that something else still holds is found
// again as itself.
void main() {
  test('a value a live draw holds is the same object after loosen', () {
    final m = LooseMap<String, _Gpu>();
    final drawn = _Gpu('drawn');
    m['drawn'] = drawn;
    m.epoch = 1;
    expect(m.loosen(1), 1);
    expect(m.isLoose('drawn'), isTrue);
    // The draw still holds it. An ask finds that object and holds it again.
    expect(identical(m['drawn'], drawn), isTrue);
    expect(m.isLoose('drawn'), isFalse);
    expect(m.length, 1);
  });

  test('asked since the close, a kept scene\'s, the held prediction\'s '
      'stay held', () {
    final m = LooseMap<String, _Gpu>();
    m.owners = 1 << 0; // scene A open
    m['a'] = _Gpu('a');
    m.owners = 1 << 1; // scene B open
    m['b'] = _Gpu('b');
    m.owners = 0;
    m['predicted'] = _Gpu('predicted');
    m['old'] = _Gpu('old');
    m.epoch = 1; // a close
    m['fresh'] = _Gpu('fresh'); // asked after it
    final n = m.loosen(1, keepOwners: 1 << 1, keep: (k) => k == 'predicted');
    expect(n, 2); // 'a' (its scene not kept) and 'old'
    expect(m.isLoose('a'), isTrue);
    expect(m.isLoose('old'), isTrue);
    for (final k in ['b', 'predicted', 'fresh']) {
      expect(m.isLoose(k), isFalse, reason: k);
    }
    expect(m.length, 3);
  });

  test('an ask adds the asking scenes to an entry\'s owners', () {
    final m = LooseMap<String, _Gpu>();
    m['shared'] = _Gpu('shared');
    m.owners = 1 << 3;
    expect(m['shared'], isNotNull);
    m.epoch = 1;
    expect(m.loosen(1, keepOwners: 1 << 3), 0);
    expect(m.loosen(1, keepOwners: 1 << 4), 1);
  });
}
