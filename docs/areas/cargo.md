# prismarine_cargo

The package builds the Rust crate of a package from its Dart build hook and ships the library as a code asset. A hook
calls `buildCargoLibrary` with the directory of the crate, the name of its library and the asset name that the
`@Native` declarations use.

```dart
await buildCargoLibrary(input, output,
    crate: 'native', library: 'prismarine_pad', assetName: 'src/native.dart');
```

Cargo comes from `$CARGO`, `PATH` or `~/.cargo/bin`. Each target needs its Rust standard library, and a macOS app build
needs both `aarch64-apple-darwin` and `x86_64-apple-darwin`. Windows builds use the MSVC toolchain. Crates that build C
with CMake need CMake, which comes from `$CMAKE`, `PATH`, Homebrew or the CMake app on macOS and Visual Studio on
Windows.

The build runs `cargo rustc --release` in a clean environment with one target directory for every configuration of the
package. On macOS the library is not stripped, since the strip of Xcode 27 leaves a dylib that dyld refuses.

## Checks

The package has no tests of its own. A build of `prismarine_pad` or of the sample app runs it.
