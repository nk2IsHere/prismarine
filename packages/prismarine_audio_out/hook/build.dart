import 'package:hooks/hooks.dart';
import 'package:prismarine_cargo/prismarine_cargo.dart';

/// Builds the package's native library from the Rust crate in native/, with
/// the vendored minimp3 and stb_vorbis decoders compiled in.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildCargoLibrary(
      input,
      output,
      crate: 'native',
      library: 'prismarine_audio_out',
      assetName: 'src/native.dart',
      extraSources: ['third_party/minimp3', 'third_party/stb'],
    );
  });
}
