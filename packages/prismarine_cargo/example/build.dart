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
