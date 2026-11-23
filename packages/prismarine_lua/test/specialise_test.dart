import 'dart:io';

import 'package:prismarine_lua/prismarine_lua.dart';
import 'package:test/test.dart';
import 'support/float_config.dart';

void main() {
  final goldens = Directory('test/corpus/golden')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.luac'))
      .toList();

  for (final config in const [FloatConfig(), FloatConfig(single: true)]) {
    test(
      '${config.numberMode}: loaded code has its mode\'s opcodes and dumps as loaded',
      () {
        final vm = LuaVm(config: config);
        var specialised = 0;
        for (final f in goldens) {
          final bytes = f.readAsBytesSync();
          final p = vm.load(bytes, '@${f.path}').p;
          for (final q in p.chunk!.protos) {
            for (final i in q.code) {
              final op = i & 0x3F;
              expect(op < Op.ADD || op > Op.POW, isTrue, reason: f.path);
              expect(op != Op.FORLOOP && op != Op.FORPREP, isTrue);
              if (op >= opFloat32) specialised++;
            }
          }
          expect(dumpFloat(p), bytes, reason: f.path);
        }
        expect(specialised, greaterThan(0));
      },
    );
  }
}
