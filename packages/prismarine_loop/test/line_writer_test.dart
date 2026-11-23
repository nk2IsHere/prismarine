import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_loop/prismarine_loop.dart';

void main() {
  test('lines read back as the JSON they were written from', () {
    final dir = Directory.systemTemp.createTempSync('lines');
    JsonLineWriter('${dir.path}/a.jsonl')
      ..begin()
      ..key('t')
      ..number(0.97294, 4)
      ..key('whole')
      ..number(480)
      ..key('neg')
      ..number(-0.0000004)
      ..key('small')
      ..number(-1.000005)
      ..key('big')
      ..integer(1794835200123456)
      ..key('nan')
      ..number(double.nan)
      ..key('s')
      ..string('a "b"\\ é\n')
      ..key('list')
      ..beginList()
      ..number(1.5)
      ..boolean(true)
      ..nil()
      ..endList()
      ..key('any')
      ..value({
        'k': [1, 2.25, 'x', null],
        'm': {'n': false},
      })
      ..end()
      ..begin()
      ..end()
      ..close();
    final lines = File('${dir.path}/a.jsonl').readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines[0], startsWith('{"t":0.9729,"whole":480.0,"neg":0.0,'));
    expect(jsonDecode(lines[0]), {
      't': 0.9729,
      'whole': 480.0,
      'neg': 0.0,
      'small': -1.000005,
      'big': 1794835200123456,
      'nan': null,
      's': 'a "b"\\ é\n',
      'list': [1.5, true, null],
      'any': {
        'k': [1, 2.25, 'x', null],
        'm': {'n': false},
      },
    });
    expect(lines[1], '{}');
  });

  test('a buffered writer writes once its bytes are kept, and at close', () {
    final dir = Directory.systemTemp.createTempSync('lines');
    final f = File('${dir.path}/b.jsonl');
    final w = JsonLineWriter(f.path, buffer: 64);
    for (var i = 0; i < 3; i++) {
      w
        ..begin()
        ..key('i')
        ..integer(i)
        ..end();
    }
    expect(f.lengthSync(), 0);
    w.close();
    expect(f.readAsLinesSync(), ['{"i":0}', '{"i":1}', '{"i":2}']);
  });
}
