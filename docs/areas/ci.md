# GitHub workflows

The workflows in `.github/workflows/` run the checks of the landing gate on GitHub runners. They run for a pull
request and by hand, from the Actions tab or with `gh workflow run tests.yml -f runners=all`. A push to `main` does not
start them. The landing gate on the Mac stays the check before every merge.

| Workflow | Runners | Steps |
|---|---|---|
| `lints.yml` | Linux | The privacy check with its generic patterns, links, docs index, code shape, alloc, analyze and format |
| `tests.yml` | Linux and Windows for a pull request. A run by hand picks Linux, macOS, Windows or all three | The tests of the lints and of the profiler, the test of the machine locks, the tests of the workspace packages and of the Flutter packages, the analysis of the Flutter packages on Linux, clippy and `cargo test` for every crate and the parity of the audio engine's Dart and native renders on its synthetic project |

`lints.yml` runs for every pull request. `tests.yml` runs for a pull request that changes a package, flutter_gpu, the
lints, the profiler, the machine scripts, the workspace pubspec or the workflow itself.

## Toolchains and caches

The workflows use Flutter 3.47.7 with Dart 3.13.5 and Rust 1.88.0, the versions of the gate. The Flutter packages run
their tests on the stock Flutter SDK with the patched flutter_gpu of `third_party`. The shader bundle test uses the
impellerc of the SDK. The sample app and gpu_smoke need the patched engine and stay in the local gate. A check that
`analyze.dart` skips for a missing toolchain fails the workflow.

The pub cache, the cargo registry and the target dirs of clippy, `cargo test` and the build hooks are cached. A cache
made for a pull request serves only that pull request. A run by hand on `main` makes the caches that every pull request
reads. Start one after a change of a toolchain or of a lock file.

## Privacy

On GitHub the privacy check runs with `--generic-only --strict`. The patterns of the private repo hold the accounts,
the hosts and the values of secrets and are not copied to GitHub. The landing gate runs the full check with `--strict`.
A path in `tools/lint/privacy_pending.txt` fails both.
