import 'package:hooks/hooks.dart';
import 'package:prismarine_cargo/prismarine_cargo.dart';

/// Builds the double and the float32 compiler libraries from the Rust crates
/// in native/f64 and native/f32. Each compiles the core and the auxlib of
/// stock Lua 5.2.3 in third_party/lua-5.2.3 with the luaconf.h of its crate.
void main(List<String> args) async {
  await build(args, (input, output) async {
    for (final (crate, library, asset) in const [
      ('native/f64', 'prismarine_luac64', 'src/native64.dart'),
      ('native/f32', 'prismarine_luac32', 'src/native32.dart'),
    ]) {
      await buildCargoLibrary(
        input,
        output,
        crate: crate,
        library: library,
        assetName: asset,
        extraSources: [
          'third_party/lua-5.2.3/src',
          'native/src',
          'native/build.rs',
          '$crate/luaconf.h',
        ],
      );
    }
  });
}
