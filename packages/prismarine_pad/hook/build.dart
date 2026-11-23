import 'package:hooks/hooks.dart';
import 'package:prismarine_cargo/prismarine_cargo.dart';

/// Builds the pad library (native/, Rust through prismarine_cargo): SDL3's gamepads,
/// read once a frame through `prismarine_pad_read`.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildCargoLibrary(
      input,
      output,
      crate: 'native',
      library: 'prismarine_pad',
      assetName: 'src/native.dart',
    );
  });
}
