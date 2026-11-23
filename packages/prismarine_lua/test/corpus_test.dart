import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/corpus.dart';

/// Every corpus program prints what the reference oracle printed.
void main() {
  for (final name in corpusPrograms()) {
    test(name, () {
      // Byte-exact: Lua strings are bytes (latin1 code units here).
      final want = latin1.decode(
        File('test/corpus/golden/$name.out').readAsBytesSync(),
      );
      expect(runCorpus(name), want);
    });
  }
}
