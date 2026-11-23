import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// An asset bundle that serves absolute file paths, such as the texture keys
/// of a scene document after they were made absolute.
///
/// A texture that is not on disk is drawn transparent black from
/// [staticBlackPng] and is reported once through [onMissing]. A missing
/// texture does not stop a scene from loading.
class FileAssetBundle extends CachingAssetBundle {
  /// Receives the message for each missing texture, once per path. The
  /// default prints it.
  static void Function(String message) onMissing = (m) => debugPrint(m);

  static final _missing = <String>{};

  /// Returns true when the file [key] is on disk. Otherwise reports the path
  /// once and returns false.
  static Future<bool> present(String key) async {
    if (await File(key).exists()) return true;
    if (_missing.add(key)) {
      onMissing('missing texture $key: drawn transparent black');
    }
    return false;
  }

  @override
  Future<ByteData> load(String key) async {
    // The read stays asynchronous. A scene asks for all its textures at once.
    // A synchronous read of them holds a frame for about 80 ms.
    if (!await present(key)) return ByteData.sublistView(staticBlackPng);
    return ByteData.sublistView(await File(key).readAsBytes());
  }
}

/// A 1×1 PNG with the pixel RGBA (0, 0, 0, 0).
final staticBlackPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, //
  0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x00, 0x02, 0x00, //
  0x00, 0x05, 0x00, 0x01, 0x7a, 0x5e, 0xab, 0x3f, 0x00, 0x00, 0x00, 0x00, //
  0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82, //
]);
