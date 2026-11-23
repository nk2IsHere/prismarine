import 'package:hooks/hooks.dart';
import 'package:prismarine_cargo/prismarine_cargo.dart';

/// Builds the package's native library from the Rust crate in native/, with the
/// vendored minimp3 and stb_vorbis decoders inside.
///
/// An app with a Rust crate of its own that depends on the crate in native/
/// sets two user defines in its root pubspec, `crate` with the directory of
/// its crate and `library` with the crate's library name. The hook then
/// builds that crate in place of native/. Its C functions and those of
/// native/ are in one library and share one decoded-audio cache.
/// docs/areas/audio_out.md has an example.
void main(List<String> args) async {
  await build(args, (input, output) async {
    final crate = input.userDefines.path('crate');
    final library = input.userDefines['library'];
    if ((crate == null) != (library == null)) {
      throw ArgumentError(
        'prismarine_audio_out: the user defines have only one of crate and '
        'library. Set both, or neither for the crate in native/.',
      );
    }
    if (library != null && library is! String) {
      throw ArgumentError(
        'prismarine_audio_out: the user define library is not a string. '
        'Set it to the name in the [lib] section of the crate.',
      );
    }
    await buildCargoLibrary(
      input,
      output,
      crate: crate == null ? 'native' : crate.path,
      library: library as String? ?? 'prismarine_audio_out',
      assetName: 'src/native.dart',
      extraSources: [
        if (crate != null) 'native',
        'third_party/minimp3',
        'third_party/stb',
      ],
    );
  });
}
