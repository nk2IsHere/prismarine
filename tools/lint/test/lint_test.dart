import 'package:test/test.dart';

import '../same_code.dart' show firstCodeDifference;
import '../src/config.dart';
import '../src/example_copies.dart';
import '../src/lexer.dart';
import '../src/rule_sets.dart';
import '../src/rules.dart';

// A config with both rule sets. It has the addresses of a 32-bit binary, a
// 64-bit binary and a DLL and a set of name words.
const _config = r'''
code_shape:
  history:
    names: [perf3, sweep102]
    pointers: ['\bSP\d[a-z]?\d?(-\d)?\b']
  rule_sets:
    exe-address:
      tags: ['\[EXE2?\b']
      ranges:
        - {from: 0x401000, to: 0xefffff, max_digits: 8}
        - {from: 0x140001000, to: 0x14fffffff}
        - {from: 0x10001000, to: 0x10ffffff, min_digits: 8, max_digits: 8}
    name-words:
      check: season-name
      word: '(^|[a-z0-9_])(S1|S2|Season2)(?=[A-Z_0-9]|$)|^_*(s1|s2|season2)(?=[A-Z_])'
      path: '(^|[/_])(s1|s2|season2)(?=[/_.])'
''';

final _parsed = LintConfig.parse('.', _config);
final _sets = RuleSet.fromConfig(_parsed.ruleSets);
final _exe = _sets.whereType<ExeAddressRules>().single;
final _history = HistoryRules(
  names: _parsed.historyNames,
  pointers: _parsed.historyPointers,
);
String? exeAddressRule(String s) => _exe.rule(s);
String? historyRule(String s) => _history.rule(s);

List<String> code(String src, Lang lang) =>
    lex(src, lang).where((t) => t.isCode).map((t) => t.text).toList();

List<String> comments(String src, Lang lang) =>
    lex(src, lang).where((t) => !t.isCode).map((t) => t.text).toList();

void main() {
  group('Dart lexer', () {
    test('comments, nested block comments and doc comments', () {
      const src = '''
/// doc
int a = 1; // trailing
/* outer /* inner */ still outer */ int b;
''';
      expect(code(src, Lang.dart), [
        'int',
        'a',
        '=',
        '1',
        ';',
        'int',
        'b',
        ';',
      ]);
      expect(comments(src, Lang.dart), [
        '/// doc',
        '// trailing',
        '/* outer /* inner */ still outer */',
      ]);
    });

    test('strings hide comment markers; interpolation nests', () {
      const src = r'''
var s = 'a // not a comment';
var t = "x ${m['k'] /* c */} y"; // real
var r = r'\d+ /* raw */';
var u = """
// inside a triple
""";
''';
      expect(comments(src, Lang.dart), ['// real']);
      final strings = lex(
        src,
        Lang.dart,
      ).where((t) => t.kind == TokKind.string).map((t) => t.text);
      expect(strings, [
        "'a // not a comment'",
        "\"x \${m['k'] /* c */} y\"",
        r"r'\d+ /* raw */'",
        '"""\n// inside a triple\n"""',
      ]);
    });

    test('operators group as the Dart scanner groups them', () {
      expect(code('a ??= b?.c ~/ d >>> 2;', Lang.dart), [
        'a',
        '??=',
        'b',
        '?.',
        'c',
        '~/',
        'd',
        '>>>',
        '2',
        ';',
      ]);
      expect(code('x - -y; x--;', Lang.dart), [
        'x',
        '-',
        '-',
        'y',
        ';',
        'x',
        '--',
        ';',
      ]);
    });

    test('numbers', () {
      expect(code('0x1F 1.5e-3 1_000 .5', Lang.dart), [
        '0x1F',
        '1.5e-3',
        '1_000',
        '.5',
      ]);
    });
  });

  group('Rust lexer', () {
    test('lifetimes, chars, byte and raw strings', () {
      const src = r'''
fn f<'a>(x: &'a str) -> char { let c = '\''; let b = b'x'; 'y' }
let s = r#"a "quoted" // not a comment"#; // real
''';
      expect(comments(src, Lang.rust), ['// real']);
      final toks = lex(src, Lang.rust);
      expect(toks.where((t) => t.kind == TokKind.string).map((t) => t.text), [
        r"'\''",
        "b'x'",
        "'y'",
        r'r#"a "quoted" // not a comment"#',
      ]);
      expect(toks.where((t) => t.text == "'a").length, 2);
    });

    test('nested block comments and doc comments', () {
      const src = '/// doc\n/* a /* b */ c */ fn g() {}\n//! inner\n';
      expect(code(src, Lang.rust), ['fn', 'g', '(', ')', '{', '}']);
      expect(comments(src, Lang.rust).length, 3);
    });

    test('`?.0` is a try then a field, not an operator', () {
      expect(code('x?.0', Lang.rust), ['x', '?', '.', '0']);
    });
  });

  group('line-comment languages', () {
    test(r'shell keeps the shebang, $# and quoted hashes as code', () {
      const src = '#!/bin/zsh\necho "#x" \$# # note\n# whole line\n';
      expect(comments(src, Lang.hash), ['# note', '# whole line']);
    });

    test('Lua block comments', () {
      const src = 'local a = 1 -- one\n--[[ two\nthree ]] local b\n';
      expect(comments(src, Lang.lua), ['-- one', '--[[ two\nthree ]]']);
    });
  });

  group('exe addresses', () {
    test('cited addresses', () {
      expect(exeAddressRule('see [EXE 0x826c50]'), 'exe-tag');
      expect(exeAddressRule('the solver (0x826c50) keeps'), 'hex-address');
      expect(exeAddressRule('global 0xdd3d80'), 'hex-address');
      expect(exeAddressRule('64-bit frame 0x14011c500'), 'hex-address');
      expect(exeAddressRule('DLL 0x100fcea0'), 'hex-address');
      expect(exeAddressRule('calls sub_826C50'), 'disasm-name');
    });

    test('constants are not addresses', () {
      for (final s in [
        'mask 0xffffff',
        'colour 0x00ff00ff',
        'bit 0x800000',
        'size 0x400000',
        '0x100000 bytes',
        'magic 0xBEEFF00D',
        'crc poly 0x04C11DB7',
        'fill 0xaaaaaa',
        'small 0x1a2b',
      ]) {
        expect(exeAddressRule(s), isNull, reason: s);
      }
    });
  });

  group('history', () {
    test('flags history', () {
      expect(historyRule('(run 20261025-104612 dump 4)'), 'run-id');
      expect(historyRule('[SRC 2026-10-26: the vendor notes]'), 'date');
      expect(historyRule('since fix-llook'), 'branch');
      expect(historyRule('instanced draws (perf3)'), 'agent');
      expect(historyRule('the port had detached it'), 'narrative');
      expect(historyRule('see REPORT-lookat §2'), 'pointer');
      expect(historyRule('SP3f made this'), 'pointer');
      expect(historyRule('research/2026-10-10/x.py'), 'date');
      expect(historyRule("the user's window"), 'user');
    });

    test('leaves ordinary prose alone', () {
      for (final s in [
        'with no orientation fix-up',
        'the user store holds the save',
        'the user-store calls',
        'the owner of the channel',
        'the route no longer replays',
        'level 8a holds the journal [SRC level8a]',
        'a vec4 of floats',
      ]) {
        expect(historyRule(s), isNull, reason: s);
      }
    });
  });

  group('rule sets', () {
    test('name words in code words and paths', () {
      final names = _sets.whereType<NameWordRules>().single;
      final hits = names.codeHits(
        'packages/a/lib/s2/look.dart',
        lex('class LookS2 { int s1Count = 0; int pass2 = 1; }', Lang.dart),
      );
      expect(hits.map((h) => '${h.check}/${h.rule}:${h.text}'), [
        'season-name/path:packages/a/lib/s2/look.dart',
        'season-name/word:LookS2',
        'season-name/word:s1Count',
      ]);
    });

    test('several sets of name words, exempt paths and every path', () {
      final c = LintConfig.parse('.', r'''
code_shape:
  rule_sets:
    name-words:
      check: season-name
      word: '^_*s[12](?=[A-Z_]|$)'
      exempt: [packages/math/]
    name-words-game:
      check: game-name
      word: '[Mm]csm'
      path: 'mcsm'
      all_paths: true
''');
      final sets = RuleSet.fromConfig(c.ruleSets).cast<NameWordRules>();
      final season = sets.firstWhere((s) => s.check == 'season-name');
      final game = sets.firstWhere((s) => s.check == 'game-name');
      final toks = lex('var s2 = mcsmEngine;', Lang.dart);
      expect(season.codeHits('lib/a.dart', toks).map((h) => h.text), ['s2']);
      expect(season.codeHits('packages/math/a.dart', toks), isEmpty);
      expect(season.checksAllPaths, isFalse);
      expect(season.pathHits('tools/s2/a.json'), isEmpty);
      expect(game.codeHits('lib/a.dart', toks).map((h) => h.text), [
        'mcsmEngine',
      ]);
      expect(game.checksAllPaths, isTrue);
      expect(game.pathHits('tools/mcsm7.json').map((h) => h.rule), ['path']);
    });

    test('a generic config has no rule sets and no agent names', () {
      final c = LintConfig.parse('.', 'code_roots: [packages/]');
      expect(RuleSet.fromConfig(c.ruleSets), isEmpty);
      expect(HistoryRules().rule('instanced draws (perf3)'), isNull);
      expect(HistoryRules().rule('see docs/plans/x.md'), 'pointer');
    });
  });

  group('long comments and functions', () {
    test('blocks over the limit; the header has a larger one', () {
      final header = List.filled(18, '// h').join('\n');
      final block = List.filled(13, '// b').join('\n');
      final src = '$header\nint a;\n$block\nint b;\n';
      final hits = longCommentHits(lex(src, Lang.dart));
      expect(hits.map((h) => '${h.rule}@${h.line}'), ['block@20']);
    });

    test('Dart and Rust function spans', () {
      final body = List.filled(160, '  x++;').join('\n');
      final dart =
          'class A {\n  void big() {\n$body\n  }\n  int get g => 1;\n}\n';
      expect(
        longFunctions(lex(dart, Lang.dart), Lang.dart).map((f) => f.name),
        ['big'],
      );
      final rust =
          'impl A {\n  fn big(&self) {\n$body\n  }\n  fn small() {}\n}\n';
      expect(
        longFunctions(lex(rust, Lang.rust), Lang.rust).map((f) => f.name),
        ['big'],
      );
    });
  });

  group('same_code', () {
    test('comments and layout are the same code', () {
      expect(
        firstCodeDifference(
          'int f(int a) { return a+1; } // old',
          '/// New doc.\nint f(int a) {\n  return a + 1;\n}\n',
          Lang.dart,
        ),
        isNull,
      );
    });

    test('formatter trailing commas and split type arguments', () {
      expect(
        firstCodeDifference(
          'final m = Expando<Map<String, List<int>>>("x");\nf(a, b);',
          'final m = Expando<Map<String, List<int> > >(\n  "x",\n);\nf(\n  a,\n  b,\n);',
          Lang.dart,
        ),
        isNull,
      );
    });

    test('a one-field record keeps its comma', () {
      expect(
        firstCodeDifference('var r = (1,);', 'var r = (1);', Lang.dart),
        isNotNull,
      );
      expect(
        firstCodeDifference('let t = (1,);', 'let t = (1);', Lang.rust),
        isNotNull,
      );
    });

    test('directive order is layout', () {
      expect(
        firstCodeDifference(
          "@TestOn('vm')\nlibrary;\nimport 'b.dart';\nimport 'a.dart';\nvoid main() {}",
          "@TestOn('vm')\nlibrary;\nimport 'a.dart';\nimport 'b.dart';\nvoid main() {}",
          Lang.dart,
        ),
        isNull,
      );
    });

    test('double to single quotes is layout when the value is the same', () {
      expect(
        firstCodeDifference('f("a \$b");', "f('a \$b');", Lang.dart),
        isNull,
      );
      expect(
        firstCodeDifference('f("a\\n");', "f('a\\n');", Lang.dart),
        isNotNull,
      );
    });

    test('strings, numbers and operators are code', () {
      expect(firstCodeDifference("f('a');", "f('b');", Lang.dart), isNotNull);
      expect(firstCodeDifference('x = 1;', 'x = 2;', Lang.dart), isNotNull);
      expect(firstCodeDifference('a - -b;', 'a--b;', Lang.dart), isNotNull);
      expect(
        firstCodeDifference('if a { b }', 'if a { b; }', Lang.rust),
        isNotNull,
      );
    });
  });

  group('example copies', () {
    const file = 'void main() {\n  print(1);\n}\n';
    String? read(String path) => path == 'p/example/example.dart' ? file : null;
    List<String> check(String md) =>
        exampleMismatches('README.md', 'p', md.split('\n'), read: read);

    test('a block equal to the linked file passes', () {
      expect(
        check(
          '[`example/example.dart`](example/example.dart):\n\n'
          '```dart\nvoid main() {\n  print(1);\n}\n```',
        ),
        isEmpty,
      );
    });

    test('a changed block and a missing file are reported', () {
      expect(
        check(
          'See [the example](example/example.dart)\n'
          '```dart\nvoid main() {}\n```\n'
          '[gone](example/gone.dart)\n```dart\nint x = 1;\n```',
        ),
        [
          'README.md:2: the example differs from example/example.dart',
          'README.md:6: no file example/gone.dart for the example',
        ],
      );
    });

    test('a block without a link before it is not checked', () {
      expect(
        check('[file](example/example.dart) and more text\n```dart\nx\n```'),
        isEmpty,
      );
      expect(check('Text.\n\n```dart\nint x = 1;\n```'), isEmpty);
    });
  });
}
