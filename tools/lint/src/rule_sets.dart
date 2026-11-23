// The code_shape rule sets that a repository adds to the generic rules of
// rules.dart. The lint config lists them under code_shape.rule_sets, each
// key with its settings. The hits of a set are counted per package under the
// check of the set and ratcheted like the generic ones.
import 'lexer.dart';
import 'rules.dart';

abstract class RuleSet {
  /// The ratcheted check that counts the hits of this set.
  String get check;

  /// Returns the rule that a comment line breaks, or null.
  String? commentRule(String line) => null;

  /// Returns the rule that a string literal breaks, or null.
  String? stringRule(String text) => null;

  /// Returns the hits in the path and the code words of a file.
  List<Hit> codeHits(String path, List<Tok> toks) => const [];

  /// Returns the hits in the path of a file that the lint does not read,
  /// such as a JSON file or a compute shader.
  List<Hit> pathHits(String path) => const [];

  /// True when the set checks the paths of the files that the lint does not
  /// read.
  bool get checksAllPaths => false;

  /// Builds the sets of [config], a map from the key of each set to its
  /// settings. A key that starts with name-words, such as name-words-game,
  /// gives one more set of name words. Throws on an unknown key.
  static List<RuleSet> fromConfig(Map<String, Map<Object?, Object?>> config) {
    final out = <RuleSet>[];
    config.forEach((name, settings) {
      out.add(switch (name) {
        'exe-address' => ExeAddressRules(settings),
        _ when name.startsWith('name-words') => NameWordRules(settings),
        _ => throw ArgumentError('code_shape: unknown rule set "$name"'),
      });
    });
    return out;
  }
}

// ---------------------------------------------------------------------------
// Exe addresses
//
// The set is for a repository whose public code does not cite addresses in
// shipped binaries. A comment or a string cites an address when it holds a
// source tag that matches one of `tags`, a disassembler label such as
// sub_826C50 or DAT_826C50, or a hex number of 6 to 9 digits inside one of
// `ranges`. A range has `from` and `to` and optionally `min_digits` and
// `max_digits`. It covers the code and data of a binary.
//
// Hex literals in code are values and do not count. Numbers outside every
// range do not count. Numbers aligned to 4 KiB and runs of one repeated
// digit such as 0xaaaaaa do not count either. These are float bits, sizes
// and masks far more often than addresses.

class AddressRange {
  AddressRange(this.from, this.to, {this.minDigits = 0, this.maxDigits = 99});
  final int from, to, minDigits, maxDigits;

  bool holds(String digits, int v) =>
      digits.length >= minDigits &&
      digits.length <= maxDigits &&
      v >= from &&
      v <= to;
}

class ExeAddressRules extends RuleSet {
  ExeAddressRules(Map<Object?, Object?> settings)
    : _tags = [
        for (final t in (settings['tags'] as List?) ?? const []) RegExp('$t'),
      ],
      ranges = [
        for (final r in (settings['ranges'] as List?) ?? const [])
          AddressRange(
            (r as Map)['from'] as int,
            r['to'] as int,
            minDigits: (r['min_digits'] as int?) ?? 0,
            maxDigits: (r['max_digits'] as int?) ?? 99,
          ),
      ];

  final List<RegExp> _tags;
  final List<AddressRange> ranges;

  static final _disasmName = RegExp(
    r'\b(sub|loc|off|dword|qword|word|byte|unk|stru|FUN|DAT|LAB|PTR)_[0-9A-Fa-f]{6,9}\b',
  );
  static final _hex = RegExp(
    r'(?<![0-9A-Za-z_])0[xX]([0-9a-fA-F]{6,9})(?![0-9A-Za-z_])',
  );

  @override
  String get check => 'exe-address';

  bool looksLikeAddress(String digits) {
    final v = int.parse(digits, radix: 16);
    if ((v & 0xfff) == 0) return false;
    if (RegExp(r'^(.)\1+$').hasMatch(digits.toLowerCase())) return false;
    return ranges.any((r) => r.holds(digits, v));
  }

  /// Returns the exe-address rule that [text] breaks, or null.
  String? rule(String text) {
    if (_tags.any((t) => t.hasMatch(text))) return 'exe-tag';
    if (_disasmName.hasMatch(text)) return 'disasm-name';
    for (final m in _hex.allMatches(text)) {
      if (looksLikeAddress(m.group(1)!)) return 'hex-address';
    }
    return null;
  }

  @override
  String? commentRule(String line) => rule(line);

  @override
  String? stringRule(String text) => rule(text);
}

// ---------------------------------------------------------------------------
// Name words
//
// The set lists words that identifiers and file paths of the code must not
// contain. The pattern `word` is matched against every identifier and `path`
// against the path of the file. The setting `check` gives the ratcheted
// count, `name-words` by default. The paths that start with one of `exempt`
// are left out. With `all_paths: true` the pattern `path` is matched against
// every file under the code roots, not only against the source files.

class NameWordRules extends RuleSet {
  NameWordRules(Map<Object?, Object?> settings)
    : check = (settings['check'] as String?) ?? 'name-words',
      _word = settings['word'] == null ? null : RegExp('${settings['word']}'),
      _path = settings['path'] == null ? null : RegExp('${settings['path']}'),
      _exempt = [
        for (final p in (settings['exempt'] as List?) ?? const []) '$p',
      ],
      checksAllPaths = settings['all_paths'] == true;

  @override
  final String check;
  final RegExp? _word, _path;
  final List<String> _exempt;
  @override
  final bool checksAllPaths;

  bool _isExempt(String path) => _exempt.any(path.startsWith);

  @override
  List<Hit> pathHits(String path) => [
    if (checksAllPaths && !_isExempt(path) && (_path?.hasMatch(path) ?? false))
      Hit(check, 'path', 1, path),
  ];

  @override
  List<Hit> codeHits(String path, List<Tok> toks) => _isExempt(path)
      ? const []
      : [
          if (_path?.hasMatch(path) ?? false) Hit(check, 'path', 1, path),
          if (_word case final w?)
            for (final t in toks)
              if (t.kind == TokKind.word && w.hasMatch(t.text))
                Hit(check, 'word', t.line, t.text),
        ];
}
