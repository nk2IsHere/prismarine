# Lints

The lints in `tools/lint/` keep the code of a repository in shape. Each one reads the settings of the repository from
`tools/lint/config.yaml`, or from the file in `$PRISMARINE_LINT_CONFIG`. Another repository can run them from a
checkout of prismarine with its own config.

| Lint | Check |
|---|---|
| `privacy_check.dart` | Private material in the tree, from the patterns of the private repo |
| `check_links.dart` | Markdown links to files that do not exist and examples that differ from the Dart file that they copy |
| `docs_index.dart` | The generated indexes of doc folders with one file per entry |
| `code_shape.dart` | File size, history in comments, long comments and functions and the rule sets of the config |
| `analyze.dart` | The analyzer, clippy, `dart format` and `cargo fmt` |
| `alloc.dart` | Places where code that a frame runs allocates |
| `same_code.dart` | Proves that a range of commits changes only comments and layout |

The ratcheted lints compare their counts with a baseline per package. A count may fall and may not grow. After a fall,
`--update-baseline` lowers the baseline.

## Config

The config lists the code roots, the baselines, the roots, SDK verdicts and Flutter packages of the allocation lint,
the variable of the private repo, the files that `check_links` reads and the doc folders that `docs_index` indexes. Under `code_shape` it
lists the agent words and pointer patterns of the history rule and the rule sets of the repository. The rule set
`exe-address` counts addresses of shipped binaries in comments and strings. The rule set `name-words` counts words that
identifiers and paths must not contain, under the check that its `check` setting gives. Each further key that starts
with `name-words`, such as `name-words-game`, adds one more set. The paths in the `exempt` list of a set are left out.
With `all_paths: true` the set also checks the paths of the files that the lint does not read, such as JSON files and
compute shaders. prismarine's own config counts seasons, episodes and the names of games, their engines and mcsm.

## Use from another repository

A repository that runs the lints from a pinned checkout depends on `prismarine_lint` through git with the path
`tools/lint`, at the same commit as its other prismarine packages. It keeps its own `tools/lint/config.yaml` and
baselines. Run a lint from the root of that repository with its package config, as in
`dart --packages=.dart_tool/package_config.json <checkout>/tools/lint/code_shape.dart`. The `rootUri` of
`prismarine_lint` in the package config gives the checkout. A small launcher in the repository can find it and set
`PRISMARINE_LINT_CONFIG`.

## Examples in READMEs

A README shows the example of its package as a copy of a Dart file that the analyzer checks. The line before the
fenced `dart` block ends in a link to that file, such as `[example/example.dart](example/example.dart):`.
`check_links` reports a block that differs from the file. A directory in the `links` list of the config is read
without its `.dart_tool`, `build`, `target` and `third_party` directories.

## Private patterns

`privacy_check` reads `config/privacy-patterns.txt` and `secrets/*.env` of the private repo. The repo is the
directory in `$PRISMARINE_PRIVATE`, else `private/` beside the main checkout. A pattern line that starts with `code: `
applies only to the files that the code lints check, outside the `comment_check_exempt` paths of the config.

## Allocation roots

`alloc_roots.txt` lists the functions that a frame calls from outside the code that the lint can follow. The lint walks
every call from these roots and counts each place that allocates. A place that must allocate carries
`// alloc: <reason>` on its line or alone on the line above. A function that a steady frame does not run carries
`// alloc-cold: <reason>` above its doc comment, or above the function when it has none. The lint reads a declaration
from its doc comment and does not see a mark between the doc comment and the function. A constructor of its own takes
the mark for the field initializers of a class.

The lint resolves the pure-Dart packages of the workspace. The Flutter packages in `alloc.flutter_packages` of the
config resolve through their own package config, such as `prismarine_render` with its runner and the sample app. Run
`flutter pub get` in each of them before the lint, else it stops with a message.

## Checks

Run `dart test` in `tools/lint`.
