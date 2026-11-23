import 'package:hooks/hooks.dart';
import 'package:prismarine_cargo/prismarine_cargo.dart';

/// Builds the compiler library (native/, Rust through prismarine_cargo): stock Lua
/// 5.2.3's core and auxlib (third_party/lua-5.2.3, with the exe-configured
/// src/luaconf.h), compiled by the crate's build.rs and called through its thin
/// wrapper.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildCargoLibrary(
      input,
      output,
      crate: 'native',
      library: 'mcsm_luac',
      assetName: 'src/native.dart',
      extraSources: ['third_party/lua-5.2.3/src', 'src/luaconf.h'],
    );
  });
}
