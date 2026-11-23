import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Serves absolute file paths: the realizer loads texture keys through
/// `bundle.load(key)`, and [rebaseTextureKeys] made them absolute.
///
/// A texture that isn't on disk is drawn with the exe's static black
/// texture (RGBA 0, 0, 0, 0; `ttcache:static_black_texture.d3dtx`), the
/// default every shader sampler parameter starts with (see formats/telltale/
/// visual/meshes.md "Textures the data names but the game never shipped"),
/// and is named once through [onMissing]. The shipped data names textures that
/// were never shipped (Ep104's obj_pigLauncherWitherA_redstoneLineOn emissive
/// map, obj_gunGatlingRedstone_glow.d3dtx, is in neither season's archives);
/// the exe draws on without them, so a missing texture must not stop a scene
/// loading.
class FileAssetBundle extends CachingAssetBundle {
  /// Where a missing texture is reported (once per path). The player points
  /// it at its log; the default prints.
  static void Function(String message) onMissing = (m) => debugPrint(m);

  static final _missing = <String>{};

  /// [key] when it is on disk; otherwise reports it (once) and returns false.
  static Future<bool> present(String key) async {
    if (await File(key).exists()) return true;
    if (_missing.add(key)) {
      onMissing(
        'missing texture $key: drawn with the static black texture, as the '
        'exe does',
      );
    }
    return false;
  }

  @override
  Future<ByteData> load(String key) async {
    // Read off the UI thread: a realize asks for all its textures at once,
    // and reading them in place held a frame for ~80 ms (TownFair).
    if (!await present(key)) return ByteData.sublistView(staticBlackPng);
    return ByteData.sublistView(await File(key).readAsBytes());
  }
}

/// A 1×1 PNG of the exe's static black texture: RGBA (0, 0, 0, 0).
final staticBlackPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, //
  0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x00, 0x02, 0x00, //
  0x00, 0x05, 0x00, 0x01, 0x7a, 0x5e, 0xab, 0x3f, 0x00, 0x00, 0x00, 0x00, //
  0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82, //
]);
