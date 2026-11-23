# prismarine_cargo

The package builds the Rust crate of a package from its Dart build hook and ships the library as a code asset. A hook
calls `buildCargoLibrary` with the directory of the crate, the name of its library and the asset name that the
`@Native` declarations use.

```dart
await buildCargoLibrary(input, output,
    crate: 'native', library: 'prismarine_pad', assetName: 'src/native.dart');
```

Cargo comes from `PATH` or `~/.cargo/bin`. Each target needs its Rust standard library. A macOS app build needs both
`aarch64-apple-darwin` and `x86_64-apple-darwin`. Windows builds use the MSVC toolchain. Crates that build C with CMake
need CMake, which comes from `PATH`, Homebrew or the CMake app on macOS and Visual Studio on Windows.

A build hook gets only some variables of the environment of the build, such as `PATH` and `HOME`. `CARGO`, `CMAKE`,
`RUSTUP_HOME` and `CARGO_HOME` do not reach it. rustup must therefore have its default folders, `~/.rustup` and
`~/.cargo`.

The build runs `cargo rustc --release` in a clean environment with one target directory for every configuration of the
package. On macOS the library is not stripped, since the strip of Xcode 27 leaves a dylib that dyld refuses.

The target directory is `cargo/` in the shared output directory of the hook. On Windows it is
`%LOCALAPPDATA%\prismarine\cargo\<hash>\`, with the hash of the shared output directory. The try-compiles of CMake
below the shared output directory of an app exceed the path limit of MSBuild, 260 characters. `flutter clean` does
not delete the directory in `%LOCALAPPDATA%`.

The crate may also be outside the package, given as an absolute path. Cargo runs in the directory of the crate and
reads the `.cargo/config.toml` files there and in its parents, such as a `[patch]` that points a git dependency at a
local checkout. Git dependencies are fetched with the git command line, which uses the URL mappings and credentials of
the machine.

## Checks

Run `dart test` in `packages/prismarine_cargo` for the choice of the target directory. A build of `prismarine_pad` or
of the sample app runs the rest.
