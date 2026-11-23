# prismarine_lint

The lints keep the code of a repository in shape. Each lint reads the settings of the repository from
`tools/lint/config.yaml`, or from the file in `$PRISMARINE_LINT_CONFIG`. Another repository can run them from a checkout
of prismarine with its own config. The details are on [the area page](../../docs/areas/lints.md).

## Usage

Run a lint from the root of the repository after `dart pub get`. A lint exits with 0 when its check passed.

| Lint | Check |
|---|---|
| `privacy_check.dart` | Private material in the tree, from the patterns of the private repo |
| `check_links.dart` | Markdown links to files that do not exist and examples that differ from the Dart file that they copy |
| `docs_index.dart` | The generated indexes of doc folders with one file per entry |
| `code_shape.dart` | File size, history in comments, long comments and functions and the rule sets of the config |
| `analyze.dart` | The analyzer, clippy, `dart format` and `cargo fmt` |
| `alloc.dart` | Places where code that a frame runs allocates |
| `same_code.dart` | Proves that a range of commits changes only comments and layout |

The ratcheted lints, `code_shape`, `analyze` and `alloc`, compare their counts with a baseline per package. A count may
fall and may not grow. After a fall, `--update-baseline` lowers the baseline. `--help` lists the options of a lint.

An example in a README that copies a Dart file stays equal to it. The line before the fenced `dart` block ends in a link
to the file. `check_links` compares the block with the file.

## Example

These commands run the quick checks of prismarine, as its gate runs them:

    dart pub get
    dart tools/lint/privacy_check.dart
    dart tools/lint/check_links.dart
    dart tools/lint/code_shape.dart
    dart tools/lint/alloc.dart
    dart tools/lint/analyze.dart --only=dart,format
    (cd tools/lint && dart test)

A Flutter package needs `flutter pub get` in its directory before `dart tools/lint/analyze.dart --only=flutter` can
analyse it. The privacy check reads its patterns from the private repo and exits with 2 when the repo is missing.

## Platforms

The lints are pure Dart and run on macOS, Linux and Windows. The clippy and `cargo fmt` checks of `analyze.dart` need
Rust.
