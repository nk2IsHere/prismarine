import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:test/test.dart';

/// The scenarios of test/corpus/tbl_len.lua and tbl_next.lua, done directly on
/// [LuaTable] exactly as their bytecode does them (NEWTABLE sizes, SETTABLE =
/// luaH_set, SETLIST = setInt from the highest index down), printed like
/// `print` and compared with the output of the reference build.
void main() {
  String show(Object? v) => switch (v) {
    null => 'nil',
    final bool b => '$b',
    final double d => const LuaCRuntime().numberToString(d),
    final String s => s,
    _ => '?',
  };

  List<String> golden(String name) =>
      File('test/corpus/golden/$name.out').readAsLinesSync();

  List<Object?> keys(LuaTable t) {
    final out = <Object?>[];
    Object? k;
    while (true) {
      final r = t.next(k);
      if (r == null) break;
      out.add(r.$1);
      k = r.$1;
    }
    return out;
  }

  test('luaH_getn matches the reference build (tbl_len.lua)', () {
    final out = <String>[];
    var t = LuaTable();
    for (var i = 1; i <= 10; i++) {
      t.set(i.toDouble(), i.toDouble());
    }
    t.set(5.0, null);
    out.add('${t.length()}');

    t = LuaTable()
      ..set(1.0, 1.0)
      ..set(2.0, 2.0)
      ..set(4.0, 4.0);
    out.add('${t.length()}');

    t = LuaTable(4, 0)
      ..setInt(4, 4.0)
      ..setInt(3, null)
      ..setInt(2, 2.0)
      ..setInt(1, 1.0);
    out.add('${t.length()}');

    t = LuaTable();
    for (var i = 1; i <= 20; i++) {
      t.set(i.toDouble(), i.toDouble());
    }
    for (var i = 1; i <= 19; i++) {
      t.set(i.toDouble(), null);
    }
    out.add('${t.length()}');

    t = LuaTable();
    for (var i = 1; i <= 7; i++) {
      t.set(i.toDouble(), i.toDouble());
    }
    t
      ..set(7.0, null)
      ..set(6.0, null);
    out.add('${t.length()}');

    t = LuaTable()..set(2.0, 2.0);
    out.add('${t.length()}');

    t = LuaTable();
    for (var i = 1; i <= 100; i++) {
      t.set(i.toDouble(), i.toDouble());
    }
    for (var i = 50; i <= 100; i++) {
      t.set(i.toDouble(), null);
    }
    t.set(200.0, 1.0);
    out.add('${t.length()}');

    expect(out, golden('tbl_len'));
  });

  test(
    'next order matches the reference build with the fixed seed (tbl_next.lua)',
    () {
      final out = <String>[];
      var t = LuaTable();
      for (final k in ['alpha', 'beta', 'gamma', 'delta', 'x', 'y', 'z']) {
        t.set(k, 1.0);
      }
      out.addAll(keys(t).map(show));
      out.add('--');

      t = LuaTable();
      for (final k in <Object>[
        3.5,
        -1.0,
        100.0,
        1099511627776.0,
        1.0,
        0.0,
        true,
        false,
      ]) {
        t.set(k, 1.0);
      }
      out.addAll(keys(t).map(show));
      out.add('--');

      t = LuaTable();
      for (var i = 1; i <= 10; i++) {
        t.set(i.toDouble(), i.toDouble());
      }
      for (var i = 1; i <= 10; i += 2) {
        t.set(i.toDouble(), null);
      }
      t
        ..set('a', 1.0)
        ..set('b', 2.0)
        ..set(20.0, 20.0);
      for (final k in keys(t)) {
        out.add('${show(k)}\t${show(t.get(k))}');
      }
      out.add('--');

      t = LuaTable();
      for (var i = 1; i <= 40; i++) {
        t.set('k$i', i.toDouble());
      }
      for (var i = 1; i <= 40; i += 3) {
        t.set('k$i', null);
      }
      out.addAll(keys(t).map(show));
      out.add('--');

      t = LuaTable()..set(f32(16777217), 'a');
      out.add(show(t.get(16777216.0)));

      expect(out, golden('tbl_next'));
    },
  );

  test('the fixed-seed order recorded with the reference build', () {
    final t = LuaTable();
    for (final k in ['alpha', 'beta', 'gamma', 'delta', 'x', 'y', 'z']) {
      t.set(k, 1.0);
    }
    expect(keys(t).join(' '), 'y beta z x delta gamma alpha');
  });

  test('luaS_hash', () {
    // h = seed ^ len; step = (len >> 5) + 1; for l1 = len; l1 >= step; l1 -= step:
    //   h ^= (h << 5) + (h >> 2) + byte[l1 - 1]   (uint32)
    expect(luaStringHash('', 0), 0);
    expect(luaStringHash('a', 0), 128);
    expect(luaStringHash('Game_NewScene', 0), 2619556465);
    expect(luaStringHash('x' * 45, 0), 2315305212);
  });

  test('key errors and next from an absent key', () {
    expect(
      () => LuaTable().set(null, 1.0),
      throwsA(
        isA<LuaTableKeyError>().having(
          (e) => e.message,
          'message',
          'table index is nil',
        ),
      ),
    );
    expect(
      () => LuaTable().set(double.nan, 1.0),
      throwsA(
        isA<LuaTableKeyError>().having(
          (e) => e.message,
          'message',
          'table index is NaN',
        ),
      ),
    );
    final t = LuaTable()..set('a', 1.0);
    expect(
      () => t.next('zzz'),
      throwsA(
        isA<LuaTableKeyError>().having(
          (e) => e.message,
          'message',
          "invalid key to 'next'",
        ),
      ),
    );
  });

  test('1 and 1.0 are one key; -0 and 0 are one key', () {
    final t = LuaTable()
      ..set(1.0, 'one')
      ..set(-0.0, 'zero');
    expect(t.get(1.0), 'one');
    expect(t.getInt(1), 'one');
    expect(t.get(0.0), 'zero');
  });
}
