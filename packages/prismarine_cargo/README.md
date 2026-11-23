# prismarine_cargo

prismarine_cargo builds the Rust crate of a package from the Dart build hook of the package. The library ships with your
app as a code asset for the `@Native` declarations of the package. The details are on [the area
page](../../docs/areas/cargo.md).

## Usage

Your package depends on `hooks` and `prismarine_cargo`. Its `hook/build.dart` calls `buildCargoLibrary` with the
directory of the crate, the name of the library in `[lib]` of `Cargo.toml` and the asset name that the `@Native`
declarations use. The crate has `crate-type = ["cdylib"]`. Give the vendored C sources that the `build.rs` of the crate
compiles as `extraSources`, which makes a change to them run the hook again.

The hook finds cargo on `PATH` or in `~/.cargo/bin`. A build hook gets only some variables of the environment, such as
`PATH` and `HOME`. It does not get `RUSTUP_HOME` or `CARGO_HOME`. Install rustup into its default folders, `~/.rustup`
and `~/.cargo`. Each target needs its Rust standard library. A macOS app build needs both `aarch64-apple-darwin` and
`x86_64-apple-darwin`, which `rustup target add` installs. A crate that builds C with CMake, such as the SDL of
`prismarine_pad`, also needs CMake and a C compiler.

## Example

The example is the build hook of a package with a crate in `native/`. It is [`example/build.dart`](example/build.dart):

```dart
// The build hook of a package with a Rust crate in `native/`, saved as
// `hook/build.dart` of that package. The crate's `Cargo.toml` has
// `crate-type = ["cdylib"]` and the library name `my_native`.
import 'package:hooks/hooks.dart';
import 'package:prismarine_cargo/prismarine_cargo.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildCargoLibrary(
      input,
      output,
      crate: 'native',
      library: 'my_native',
      assetName: 'src/native.dart',
    );
  });
}
```

The asset name `src/native.dart` matches a library in `lib/src/native.dart` that starts with
`@DefaultAsset('package:<your package>/src/native.dart')`.

## Platforms

The hook builds for macOS on arm64 and x86-64, Linux on x64 and arm64 and Windows on x64 and arm64. Windows builds use
the MSVC toolchain of Visual Studio.
